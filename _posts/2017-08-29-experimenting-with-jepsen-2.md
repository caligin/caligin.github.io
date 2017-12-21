---
title: Experimenting with Jepsen - 2
---

I've been recently experimenting with [Jepsen](https://github.com/jepsen-io/jepsen/) as a test harness for correctness of computation in distributed systems. In [the previous post](https://caligin.github.io/2017/08/29/experimenting-with-jepsen.html) I went through building the harness on a local Vagrant cluster and a first approach at modeling the test. In this post I'll pick up from my earlier doubts about representing the system and refine from there.

To quickly recap where I was at: the mock infrastructure is comprised of three Centos7 boxes clustered together, each one running:
- a [MongoDB](https://docs.mongodb.com/) node
- a [RabbitMQ](https://www.rabbitmq.com/) node
- a node of a demo application (managed by the Jepsen test itself)

and the demo application:
- represents a [FSM](https://en.wikipedia.org/wiki/Finite-state_machine)
- stores state in MongoDB
- reads a message from Rabbit, uses it to transition the FSM
- uses an unsafe read-modify-write pattern
- its FSM has a catch-all terminal state that represents an error condition

I saw a successful test run with the system modeled as a `CASRegister` and a linearizability checker but that doesn't actually sound alright so let's revisit this design.

## What are we even testing, anyway?

First of all: using a `CASRegister` as a model cannot be right. While implementing a CAS operation in MongoDB is possible, it's not what we're doing in the demo application. We can just read and write, so a more appropriate model is a `RWRegister` instead: pretty much the same but not capable of an atomic CAS operation. Doesn't sound like much but it can make all the difference when dealing with concurrent access. [Knossos has a register model](https://github.com/jepsen-io/knossos/blob/master/src/knossos/model.clj#L61) but at this point I'm still thinking in terms of FSMs, so I end up [writing my own implementation](https://github.com/caligin/jepsen-playground/blob/81995cf1dcff9c1fa8a0e5b88c57cf3d27a8829e/jepsen.consumer/src/jepsen/consumer.clj#L115) that leverages the client-side copy of our little demo FSM.

This makes more sense, intuitively. Run the test, it appears to linearize. Uhm, really? Run it again... boom! It runs out of memory on my laptop! And same for any run thereafter. What gives? A thing that I didn't really understand well at this point was the actual concept of linearization: [some more reading](https://aphyr.com/posts/313-strong-consistency-models) helped me understand that given a recorded history, to be able to say it's linearizable it needs to be verified against multiple rearranged versions of it. No surprise this takes loads of memory!

So hypothesis: the system is not linearizable, the successful run was a lucky one that happened to generate a history that *looked* linearizable and verifying those histories requires a system with more than 16GB RAM.

Fast forward a few days, I get access to my PC (32GB RAM) and confirm that yes, the test runs actually fail. The system is not linearizable and it's confirmed so now it's time to make it be.

## A more balanced view

Before heading into making the system more consistent, there's a layer of indirection missing: the real system we're trying to model is also loadbalanced on reads with an [HAProxy](https://www.haproxy.org/) cluster. This has quite an impact on disrupting the locality of client-app-db connections across the system so let's add this extra layer of realism in the mock infrastructure before moving forward.

HAproxy is straightforward to install and configure so the only thing to point out is that SELinux doesn't like it forwarding traffic to a backend on port 8888. This drove me utterly mad because when SELinux gets in the way it never says it clearly, it's always an hour of fun digging into syslog and stracing aggressively.

For the sake of the experiment I disabled SELinux altogether (didn't invest time into modifying policies yet) but keep in mind that this is bad, SELinux is your (annoyingly passive-aggressive) friend and don'tdon'tdon'tdon't do this in production.

## If you like it consistent put a lock on it

In my previous post I touched on the fact that to savage the day when we first detected race conditions in "µservice A" was to implement a distributed semaphore in RabbitMQ to have only one instance of the service processing writes at a time (plus failover). That was not a good idea so let's do it again! This time although we'll use something a little better than Rabbit for the task: a [Consul](https://www.consul.io) cluster.

First let's see how to build a cluster: Consul is distributed as a single binary, but we want a service managed by the OS. Despite my total unfamiliarity with systemd beyond [its fame of enraging sysadmins](http://without-systemd.org/wiki/index.php/Arguments_against_systemd) it doesn't take a lot of duckduckgoing before figuring out what a unit file is and how to copypaste the one from Mongo and tweak to my needs. The one thing I missed at first though is that to be able to `enable` the service the unit file must contain an `[Install]` section with a `WantedBy` specification. You likely want to set this to `multi-user.target`. As per the config file, the auto-bootstrap does pretty much everything by itself. I hardcoded the ip addresses of the cluster nodes in the `retry_join` section to make it quick but that's probably the only thing worth noticing in an otherwise vanilla config.

Now, why Consul? Well, its clustering is bases on [Raft](https://raft.github.io/), and it provides an API to acquire locks that [can easily be used to implement leader election](https://www.consul.io/docs/guides/leader-election.html). Unfortunately most available libraries don't provide an implementation of the lock API so it boils down to hitting the HTTP endpoints directly. Creating a session and acquiring a lock is straightforward, but remember that sessions needs refreshing and failing at lock acquisition needs retrying periodically to make the failover magic happen! Still, [40 or so lines of clojure](https://github.com/caligin/jepsen-playground/commit/bac7444fcd31dcef1437cbe216e10bd4bfe09e87) are enough to build it.

Run the test. Drum roll. Fail!

Taking a closer look at the failure log reveals something I didn't expect: the errors are not about the state of the FSM getting stuck in the error catch-all, they're about the wrong writes being sent over!

## Loosening the screws

Let's recap for a second what a *wrong write* means in this context: the test system, `µservice A`, implements a FSM. A write represents an event that would trigger a state transition. This FSM although is very picky: while in a state, there is only one event that would advance the state to an "active" one and anything else will force the state to a catch-all state with no outgoing arrows called `b0rk`. For the purposes of this post, I'll define a *wrong write* as a write that transitions an FSM to the `b0rk` state. Moreover, I'll point out that due to the lack of observable changes in the system after a state gets stuck to `b0rk`, given this definition any write after a wrong one is neither *wrong* nor *write*: we just can't tell anymore. And it doesn't matter, once it's broken it's broken.

At this point, the tests are failing due to wrong writes being detected. The writes are generated by a single, thread-safe generator that implements a copy of the server-side FSM so they are guaranteed to be in the correct order: intuition then suggests that what the model is keeping track of receives reads out-of-sync with the actual server-side state and hence deems the next write illegal.

The reason to represent this consistency constraint in the model is to be able to evaluate correctness based on the generated/observed history of operations, but our case is a weird one: this responsibility is somehow already implemented by the server, by means of the catch-all `b0rk` state. We can therefore drop the check on the writes and simplify the implementation of our model: it is consistent as long as a step-by-step reduction of the history never observes a `b0rk` on a read.

Nevertheless, even with our relaxed constraints the test does not pass.

## Tightening the bolts

Levers. Who doesn't like pulling levers? Turns out that there are two safety-performance levers that I've not pulled yet.

The first is on the Rabbit consumers and it's called the `basic_qos`: when there are a bunch of messages on a rabbit queue with multiple consumers, they get dispatched to them in batches. The consumers then see, process and ack them one by one but the rest of the batch is "on hold" on that consumer. Setting the qos limits the size of this preflight batch, and limiting it to 1 can trade off some performance to attenuate (but definitely not solve!) problems around processing order and competing consumers. This doesn't actually change much and probably has more of an impact if your consumers have a worker threadpool but I'll set it to 1 just in case.

Now on for Mongo: the lever here is called [write concern](https://docs.mongodb.com/manual/reference/write-concern/) and determines how mongo acks a write. By default a write "completes" from the driver's perspective once 2 nodes ack it. This might not be enough to guarantee that the write is persistent in various failure scenarios and the safe setting here is called `journaled`: wait for an ack from the majority of the nodes in the cluster and instruct them to ack after committing the write in their oplog instead of being happy to just see it in flight.

Turns out that neither of these helps for the test scenario, roughly 1/3 of the test runs keep failing.

## Wrong all along

At this point I was at a loss. The generator is not supposed to yield operations in an order that can be considered illegal in the first place, and the requirement of writes to match the last read value has been lifted. So why does the model still think that the writes are wrong?

I end up staring in disbelief at the generator, that I'm sure I wrote to be thread-safe. But wait, why would I even do that? Well, because by default there are 3 client threads! That meaning, that even if the generator yields operations in the right order the 3 client threads have no way to guarantee that they are then *carried out* in the same order! And this not only explains the failure, but also means that I've been wrong in my conclusions since the beginning by virtue of making the incorrect assumption that the writes are always happening in a legal order and inconsistency has to be introduced by the server side code.

## Welp, enough!

That realization was enough for me to decide that is was time to take a break, look back and draw some conclusions.

First of all I'd say that early during this story I already had a "false conclusion point", that I even presented to my colleagues, at which I thought that Jepsen was the wrong tool for the job. Meaning that, the framework and the abstractions it provides really feels that it's meant for testing very specifically a single memory registry in a system under unfavourable conditions, with the goal of making statements about its serializability properties in these situations. What I was pursuing at the beginning instead was a tool to test the correctness of a whole µservice (and its surrounding layers of infrastructure) under normal operation. And on top of this the fact that "µservice A" implements a weird FSM to start with didn't help with the feeling of weirdness.

Still, after progressing with the experiments I understood various more things: first of all, in a µservices architecture each one of the services would ideally "do one thing". While this is not necessarily strict nor true I think it's fair to generalize that every µservice encloses 1 to 3 externally visible entities, meaning that even if Jepsen is designed to test an entity in a service and not a whole service the two are still roughly equiparable and worst case we write 3 harnesses for a single service. Following this, speaking about correctness of the whole system doesn't make a lot of sense from a testing perspective when the service encloses behaviours that are completely noninterferent. No much point of observing them together in that case: verifying them one by one is more than enough.

Lastly, and probably more importantly: despite my firsthand feelings that I picked the wrong tool I think that, even in a scenario in which things are not correct to start with, building a very lax Jpesen test harness and then tighten it bit by bit while building correctness, consistency, resilience and generic awesomeness in your software is still a valuable way to track and verify progress. So for now I'll deem this experiment reached its conclusion, but I expect in the future to pick Jepsen up again from the start and use it in a reasonably different way to drive and track the evolution of a distributed application.

