---
title: Experimenting with Jepsen
---

A year ago, as I joined a new project, I had to face right away a consistency problem.
The project was developed with a µservices architecture deployed monolithically on an on-premise infrastructure, and because limitaitons in resources and influence all of the µservices were deployed in 1x on a single box. We actually had a second box and just in the few days before I joined some work was done to deploy one of our services on both boxes: problem is, as soon as we did it most operations carried on by that service started saving data in inconsistent states.
 Knowing that our stack is based on [RabbitMQ](https://www.rabbitmq.com/) and [MongoDB](https://docs.mongodb.com/), the situation had the smell of a poorly written distributed system all over. And in fact after building a [smaller scale example of the problem](https://github.com/caligin/competing-consumers-ordering-spike) we were able to demonstrate that it was. Unfortunately, given the lack of scope at the time we ended up implementing a [distributed semaphore in RabbitMQ](https://www.rabbitmq.com/blog/2014/02/19/distributed-semaphores-with-rabbitmq/) (despite knowing that [it wasn't a great idea at all](https://aphyr.com/posts/315-call-me-maybe-rabbitmq)) and moved on, hoping that it would to buy enough time to come back at it with a more robust solution.

Fast forward one year later, our services estate grows, the uneasiness of not having any form of failover (except that one lock on that one service) grows and the hunger for some form of high availability on all services grows, especially because not having it implies late-night deployments to avoid disservice. The problem is that we realize that probably more than a half of our services, being designed with a linear world in mind, would likely exhibit the same behaviours we already observed in, let's call it µservice A. At the same time we know that if we really need it we can just put a lock on it but that's greatly suboptimal as it buys us availability but hinders scalability and ultimately just delays an actual solution again.
We finally set up a task force to tackle the issue on the whole µservice estate, and a question arises: how do we build a test that can demonstrate the problem and the effectiveness of whichever solution we come up with? I had my deal of reading about [Jepsen](https://github.com/jepsen-io/jepsen/) and thought that it might be the right tool for the job: this is what I learned in the last couple of weeks of hacking on it late at night.

## µService A

What are we trying to reproduce? Our problem µservice looks pretty much like this, in the language of boxes-and-arrows:

```
 ______                 __________     ______________     ___________
|      | read message  |          |   |              |   |           |
|rabbit|-------------->|mongo read|-->|fsm transition|-->|mongo write|
|______|               |__________|   |______________|   |___________|
```

So the main responsibility of this service is to receive events related to an entity in our domain and progress a finite state machine (fsm from now on) related to it based on the current state and event received. Transitions are expected to be received in a "legal" order on the queue and trying to apply an undefined/unexpected transition will result that fsm to fall into a "'tis broken" catchall terminal state. The problem then arises when:
- the AMQP client consumes messages in batches and process them on a threadpool
- multiple instances of the service are all bound to the same queue: rabbit will dispatch messages in a round-robin fashion among the clients

In both cases reads and writes will be able to interleave, potentially leading to *lost updates*: the impact on µservice A is that two events dispatched on the queue in a specific order, meant to consistute a legal transition (let's say `e1` and `e2` that would transition `s0` to `s1` to `s2`, processed by two threads or processes `t1` and `t2`), can now interleave causing the following scenarios:

- `t1` and `t2` happen to serialize correctly, and everything is fine
- both `t1` and `t2` read `s0`, they cause the transitions `s1` and `s1'`
  - `t1` writes first: `t2` will overwrite the final state with `s1'`, which is not meant to be the correct end state
  - `t2` writes first: `t1` will overwrite the final state with `s1` but the results of the transition `t2` will be lost
- `t1` and `t2` serialize, but in inverse order: the final state will end up being an unintended one
- I think that covers it but we're speaking race conditions here, I might have missed a scenario `¯\_(ツ)_/¯`

We need to figure out why this is happening and study better the consistency prperties of our service so let's start by going over the stack we're using:
- [RabbitMQ](https://www.rabbitmq.com/)
- [MongoDB](https://docs.mongodb.com/)
- [Clojure](https://clojure.org/) ([Langohr](http://clojurerabbitmq.info/), [Monger](http://clojuremongodb.info/))
- [CentOS](https://www.centos.org/)

So now we can argue that this is caused by any number of factors among dispatching ordered commands on a queue, using MongoDB incorrectly, using MongoDB, using RabbitMQ, cosmic rays, badly written software or a conspiracy orchestrated by the Distributed Illuminati. But the cause nor the solution are of any importance here: what we want, before doing any amount of work to deal with any inconsistency in service distribution is to have an automated test that can reproduce the issue and demonstrate our success after we deal with it.

## Building a playground

So my first thought is to build a playground where to set up a skeleton Jepsen test against a fake version of µservice A. The first goal is to explore the tool and get something that, as much as it's just hacked together, can serve as a starting point to iterate on.
The idea is to use [Vagrant](https://www.vagrantup.com/) to build and provision a cluster of CentOS boxes, start our fake test subject inside the cluster and point Jepsen at it. There would be no [nemesis](https://github.com/jepsen-io/jepsen/blob/master/doc/nemesis.md) involved for now as we already know that in all of this *the real nemesis is our own design*.

## Integrating Vagrant

I started from the [scaffolding section in the docs](https://github.com/jepsen-io/jepsen/blob/master/doc/scaffolding.md), that suggested the first step would be to have a `noop` test connect to a Vagrant cluster.

The cluster is created with a [multi-machine `Vagrantfile`](https://www.vagrantup.com/docs/multi-machine/) declaring 3 [CentOS7 boxes](https://app.vagrantup.com/centos/boxes/7). Jepsen expects to be able to resolve the node DNS names or to connect directly by ip address. Vagrant doesn't have any integration with the local DNS resolver out of the box and that leaves a missing link between the randomly generated IP addresses of the boxes and our ability to reference them with a stable name. I decided that setting the vm networking to `:internal_network` with statically assinged IPs was the approach that would result most frictionless for future uses (optimize to reduce friction of use VS minimizing edits).

Next, connecting: a Jepsen test supports configuring an ssh_key but from my understanding it needs to be the same for all nodes (passing a `fn[node]` would be cool, unless it's already possible and I missed it). Vagrant bootstraps its boxes with the `default_insecure_key` but quickly replaces them with newly generated keys. So for how much I'm a big advocate to securing everything by deafault from the start, given the objective to quickly build a PoC the decision was to configure Vagrant not to replace the keys and tell Jepsen to use Vagrant's `~/.vagrant.d/insecure_private_key` to ssh in.

On top of this I had some trouble passing the configuration to the test, it looked like being overwritten during the `merge` call. Not sure if it was really happening or not but I ended up getting rid of cli options. And when the test starts it still prints "starting test with all the default options" but then it does what I want so fine, whatever.

[This](https://github.com/caligin/jepsen-playground/tree/707a6dde6d70ae7a53f86f6dc2eb934cbc06311f) is how the repo looks like at this point.

## Provisioning

I need a bunch of things on those VMs in order to run my application, and I don't really want to use a `jepsen.db` to orchestrate all of this, so [Vagrant provisioners](https://www.vagrantup.com/docs/provisioning/) are the obvious choice. An [Ansible](https://www.ansible.com/) provisioner would be ideal, but for the sake of simplicity (and the realtively tiny size of required infra) a bunch of `shell :inline` provisioners will do.

I don't think there is much interesting stuff to note about writing the provisioning code other than with me being forgetful it resulted in a lot of *trial-and-error-and-oh-whooops-I-missed-that*.

Couple a gotchas around hostnames and Rabbit/Mongo clusters though: Rabbit [expects to use hostnames for clustering](https://www.rabbitmq.com/clustering.html), and to have all nodes being able to resolve names of all other nodes so there is no running away from messing with `/etc/hosts`. Mongo instead doesn't mind, but you'll need to use IP addresses as they are later passed to a connecting client, which being outside the VM would not be able to resolve names resulting in connection failure.

By [this commit](https://github.com/caligin/jepsen-playground/tree/72088bc9472dcee80bf65cefd17bfbf84f728cb2) all the provisioning starts feeling solid enough (and looking in dire need of a refactoring!) and gotchas have been discovered and taken care of.

## A test subject

The demo test subject will be a small Clojure application that replicates µservice A, described above, on a smaller scale. It will read a state transition message from a Rabbit queue, load some current state from Mongo, appy an fsm transition, save the new state. The fsm is a simplistic one with four states: `initial`, `transitional`, `terminal` and "something went wrong" (`b0rk`). The application results being very few lines other than plumbing together Langohr and Monger and there is nothing much to say about it. It gets introduced with [this commit](https://github.com/caligin/jepsen-playground/commit/209f9566bd98021f3e7fded87a22dbe0a4c7086a).

The produced uberjar is then deployed on the boxes with Vagrant provisioners but not started: we'll have Jepsen take care of starting and stopping it with [an implementation of the `DB` protocol](https://github.com/caligin/jepsen-playground/commit/3e245c1b410f144a9382829b1e83563fe3f7c8f5). Unfortunately the `start-stop-daemon` utility provided in `jepsen.control.utils` doesn't work for this setup as it relies on tooling not available on CentOS7, I had to go for a direct `exec` on `java` instead. The process needs to output to a logfile for later retrieval and go in the background. The teardown process will then need to rely on a `pkill` as we don't have anything fancy as pidfiles. The `|| true` ensures that the call doesn't fail when a pre-run teardown happens and doesn't find any `java` to murder. As a bonus, we'll have Jepsen clear the Mongo database during the teardown process to keep runs clean. Expecting potential escape awkwardness from running a command line Mongo `drop` from clojure I used Monger instead, it's simple enough to set up and easier to reason about.

## What to throw at it?

So our µservice keeps track of a number of entities, each one with its own state, and applies state transitions taken from a Rabbit queue on them.

What sounds like the natural way of modelling the operations our client will execute is then one operation for each state transition: three form of writes (`new`, `update`, `terminate`) parametric on the `id` of the entity to apply it onto. A normal entity lifecycle starts with an invocation of `new`, followed by any number of `update`s, then a `terminate`. To simplify we'll say that the `update`s are exactly four and we'll use a `seq` generator to emit operations in order (with the whole sequence parametric on `id`). We'll then pick operations from a bunch of these independent `seq` generators with with a `mix` generator.

The client implementation will execute these operations all in the same way: sending a Rabbit message with some properties based on the `:op` and `:value` values for the current operation. [This](https://github.com/caligin/jepsen-playground/blob/72088bc9472dcee80bf65cefd17bfbf84f728cb2/jepsen.consumer/src/jepsen/consumer.clj#L51) is how it looks like.

## A model for checking

Now we need to model how a correct world looks like. To be honest from a quick read at the docs I'm not sure I understood the reasoning behind how a model should be defined very well so trying to hack stuff together quickly I went for the first thing that sounded natural: to model it as an fsm. That resulted in reimplementing the fsm logic on the test side, with state kept in a map to keep track of it on a by-entity basis.

To be honest some doubt started piling up at this point: I'm generating a number of writes against a system with a certain logic, sending them over (with no feedback whatsoever) and then checking that the history of generated writes conforms to the model. With the model being a different description of the generator logic. The real question is "What am I even testing?", but I got to formulate it only a few hours later, after managing to see a [first successful run](https://github.com/caligin/jepsen-playground/commit/9f1224c90a6e5b94bc4dd7ac32a9fab6df62905b) with a `linearizable` checker. Then for a few runs the program didn't terminate at all and needed to be killed, that lead me to think that maybe a linearization checker is not as cheap to run as I thought. This in turn led me to read some [more docs](https://github.com/jepsen-io/jepsen/blob/master/doc/refining.md) and [blogposts](https://aphyr.com/posts/314-computational-techniques-in-knossos) and understand a little better what we're going about.

## Remodelling

At this point it's clear that my model is somehow wrong. I search among examples and blogposts expecting to find some form of multi-value example of a model, but it seems that everything is based on the `CAS` model. Why would that be, surely if you're testing a database you'll take in account more than a single entity right?

Wrong. We're speaking linearization properties here. Operations on two different entities are noninterferent by definition so it makes no sense at all to take more than one entity into account! A model can easily be an fsm on a single entity rather than tracking the state of multiple entities.

But then doesn't the generator look too simple and small? And again, if all we do is write conforming to the rules, what are we checking at all? We probably want to interleave some form of reads with the writes. But where in the fsm lifecycle?

While struggling to wrap my head around making this simplification effective, I looked at the `CAS` model again and only then it occurred to me: the fsm model is actually irrelevant. What we're looking at is just a manifestaiton of a generalized problem of *lost update*. Therefore modeling as a `CASRegister` with writes being messages on Rabbit and reads directly from Mongo (or an HTTP endpoint for added realism) is perfectly fine.

## Next

I still need to do this remodeling and honestly it might come out somehow differently as read and writes now make sense but I'm still confused about the CaS operation itself. Still, this short journey to get here had some learnings to give and I expect to see more while finalizing and refining the test harness.

It's been a long year before being able to get here, but we somehow made it.

