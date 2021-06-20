---
title: "Building a Magic: the Gathering server (ft. Kubernetes security)"
author: Foo
layout: post
tags: [k8s, "Security Engineering"] 
---

I know, at first "building a MTG server" doesn't sound very _security_, does it? Nor it would sound very _engineering_, but stick with me for a sec, ok?

Thing is, this became a reasonably self-contained study case for what risks to consider when deploying simple applications on Kubernetes, and which simple protections you should be aware of and include in your namespace and pod configurations.

## Some great stories start with a pint of beer...

As it happens, a couple of weeks ago I had the chance to catch up in person with a friend of mine. We've not seen each other for several months, and while chatting about how's our life been over a pint (or twenty), I end up mentioning that I recently had the random urge to play some [Magic: the Gathering](https://magic.wizards.com/en) and ended up digging out some old decks, as well as printing a bunch more for practice play. Turns out he used to play too, and we get excited at the idea of playing a few games together. Problem is, we live about 30+ tube-minutes away so for how great in-person play is, also having an online option helps.

These days there are at least 2 official online platform for MTG, but as far as I know even in these online formats you need to throw money at the game to unlock the cards to play. Maybe ok for competition players, not exactly what I'd like for some very casual games. I remember though of the good ol' [Cockatrice](https://github.com/Cockatrice/Cockatrice/) project - a FOSS MTG workbench that supports online play, and ships with its own server software called `servatrice`.

As we leave the pub, this is the plan: deploy our own private server and have a few casual games.

## The technical context

Since 2020 I decided to invest some money in the tiniest possible [Kubernetes](https://kubernetes.io/) (k8s for short) cluster. This serves the dual purpose of being a space where I can deploy my pet projects, as well as being an excuse to improve my k8s skills. I won't cover the full detail of it in this post, but there are a few points that are relevant context for the rest of this post:
- it's a [DigitalOcean](https://m.do.co/c/0b6a6e56d149)-managed cluster (referral link)
- there is a single Ingress Controller for all applications deployed there, with [cert-manager](https://cert-manager.io/) installed
- there is a single Load Balancer in front of the Ingress Controller
- there are a bunch of unrelated apps running on the cluster - each is in its own namespace
- I don't have a managed DB nor do I want one at the time, as I'm trying to go cheap
- the base configuration of the cluster, namespaces and DNS is done manually with a mix of `kubectl` and Terraform
- I'm using GitHub Actions for CI/CD of apps to the cluster
- I have a private Docker registry, also hosted on DigitalOcean

Also, please note that I won't cover the basics of k8s resources and in the rest of the post I'll assume a base degree of familiarity with Pods, Deployments, ConfigMaps, Roles, Namespaces, Ingresses, `kubectl` and a bunch of other bits and bobs.

## What's servatrice?

[Servatrice](https://github.com/Cockatrice/Cockatrice/wiki/Setting-up-Servatrice) is the server component of Cockatrice. What I understand from the wiki is that it's essentially a messaging hub that allows players to find other people to play, chat and then enables the game clients to communicate for an online match. It doesn't feature anythig special or weird besided being some server-side software that listens on some port and optionally supports using a DB to remember about users and their profiles.

Looking at the technology side, servatrice is written in C++ using the QT libraries, communicates with client over plain TCP or WebSockets and is built in a Docker container provided as part of the sources.

## What can possibly go wrong?

When planning a deployment it's good to understand what is the risk profile of the technologies involved. I am a big fan of [Threat Modelling with timeboxed STRIDE](https://thoughtworksinc.github.io/sensible-security-conversations/) as a team exercise for understanding risk, but in this case I'm on my own and a lo-fi brainstorm of some gut-feel risks will be enough. So, what can go wrong?

Servatrice is written in C++, a language that does not offer memory-safety as a default. I do not use C++ often enough to be able to determine the safety of servatrice from a quick code review, but just the fact that it's C++ makes me slightly uneasy, and even if the code is very readable and appears to be taking security in considerations, a few points (e.g. some `if/else` blocks with no braces, a newline away from bugs) convince me to stick with the paranoia and consider the possibility of a network-exploitable vulnerability to be very real.

Let's say that an ill-intentioned player is able to exploit a memory bug via a legit network connection and pop a shell inside my k8s cluster: now what? Well, without protections they would be able to:
- download and run any software in the servatrice container
- communicate with other network services within the cluster, including services not exposed via Ingress and Load Balancer
- interact with the cluster control plane with a pod default Service Account Token
- tamper with binaries in the container to perform other attacks

Moreover, not k8s specific:
- an unencrypted client connection to the server can be intercepted and snooped on, leading to information disclosure
- an unencrypted client connection to the server can be intercepted and tampered with, leading to injection and exploiting of client software
- an unauthenticated server would allow trolls and griefers scanning the internet to come and causing disruption for the lulz (their lulz, certainly not mine)
- having a database opens a whole new can of SQL worms, including storage of user information and passwords

## What are we going to do about it?

For deployment and configuration, I'll pick a deployment without database. I'm trying to go lean and cheap, so I don't want to spend neither money nor time in configuring a DB for this. A DB would allow to force users to be registered and authenticated, but the fact that I see Sha512 rather than Bcrypt for password storage makes me a bit uneasy, and given that this is meant for a handful of players only a shared password set via configuration would be more than enough.

Regarding transport security, the websocket connector supports TLS by reverse proxying and terminating TLS on the proxy. This is perfect as it's exactly what an Ingress Controller does, plus the certificate management. According to servatrice's wiki, [some minor tinkering with nginx proxy headers is needed](https://github.com/Cockatrice/Cockatrice/wiki/Using-NGINX-to-Wrap-Servatrice-Websockets-in-SSL) to make this work. Sounds good.

What about the risk of exploitation then? Well luckily k8s and Docker provide a bunch of ways to lock things down, we'll look at some of them in the rest of the post as we build our server:
- unprivileged execution
- NetworkPolicies
- disabling Service Account Token
- read-only filesystem
- multi-stage builds to reduce attack surface in the container

## Preparing a namespace

Whenever I want to add an app to my k8s cluster, I usually start by creating the namespace. This is because I use namespaced RBAC permissions to control access to the various namespaces, so that my CI/CD pipelines for an application can only interact with what they need to create a deployment, only in their pertinent namespace. So starting from the namespace means that when I get to packaging the software I already have a KUBE_CONFIG that allows shipping it. While in the context of this story it might sound that I'm skipping over some important detail of how this came to be - and I am indeed! - I would like to point out that in building out a technology estate over time, be that a bunch of pet projects or an actual company, it's important to identify, capture and reuse patterns as they emerge. In my case, with trial and error I ended up standardising an "app namespace bootstrap template" and adding a little automation around with with `make` and `sed`, plus a few lines of `bash` to handle registry authentication and namespaced kubeconfigs. Details of all of this is material for their own story - but I'll add relevant snippets below as we go.

So, we are starting with this template, that assumes a 2-tier webapp:

```yml
# app.yml.tpl

apiVersion: v1
kind: Namespace
metadata:
  name: APP_NAME
  labels:
    name: APP_NAME
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: github
  namespace: APP_NAME
---
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  namespace: APP_NAME
  name: APP_NAME-deployer
rules:
- apiGroups: ["", "extensions", "apps"]
  resources: ["deployments", "replicasets", "pods", "services"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: APP_NAME-deployer
  namespace: APP_NAME
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: APP_NAME-deployer
subjects:
- kind: ServiceAccount
  name: github
  namespace: APP_NAME
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: APP_NAME-ingress
  namespace: APP_NAME
  annotations:
    kubernetes.io/ingress.class: "nginx"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  tls:
  - hosts:
    - APP_NAME.example.com
    secretName: APP_NAME-tls
  rules:
  - host: APP_NAME.example.com
    http:
      paths:
      - path: /
        pathType: ImplementationSpecific
        backend:
          service:
            name: APP_NAME-frontend
            port:
              number: 80
      - path: /api/v0
        pathType: ImplementationSpecific
        backend:
          service:
            name: APP_NAME-backend
            port:
              number: 80

```

Simple enough: there's a Service and Ingress for a TLS-enabled 2-tier webapp, a Role for GitHub deployments and nothing else. `APP_NAME` is a placeholder that I replace with `sed` before doing further edits - I'll rename it as `mtg` for the rest of the post, replace it with whichever name makes sense to you. And same is valid for `example.com` - you'll have to use your own domain.

### Network restrictions

The security inclined would indeed notice that this template misses on an important control in a k8s namespace: a default NetworkPolicy. It's an unfortunate default, but by default in a k8s cluster there is no network restriction whatsoever aound what can communicate where, even across namespaces. In order to do so, the recommendation is to always start by adding a policy that default denies all egress and egress - then add more policies to allow the necessary traffic.

To learn about NetworkPolicies and draft them, I used the excellent [web editor by Cilium](https://editor.cilium.io/), that provides a graphical representation of your yaml and a step-by-step tutorial.

Using it, I first draft a default deny policy:

```yml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mtg-default-deny
  namespace: mtg
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress: []
  egress: []

```

Then, what do we need to allow? For sure ingress traffic needs to be allowed from the Ingress Controller namespace to forward traffic to the servatrice websocker port (4748), and we'll allow the Pod to contact k8s's internal DNS, even if I suspect it's not stricly needed in this case. Lastly, and I discovered this only a few TLS failures later, we also need to allow the Ingress Controller to forward to Cert-manager to solve an [ACME HTTP challenge](https://cert-manager.io/docs/tutorials/acme/http-validation/).

Our completed policy looks like this, but hold on your CTRL+C just yet:
```yml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mtg-network
  namespace: mtg
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: ingress-nginx
      ports:
        - port: 4748
        - port: 8089
  egress:
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - port: 53
          protocol: UDP
```

This looked all good and fine as it came out from Cilium web editor, but later on (after actually deploying something in that namespace - that we'll cover in a few steps) all I got from connecting to the public URL was a bunch of TLS errors and 504 responses. To debug this, I first looked at the servatrice logs with `kubectl -n mtg logs <servatrice-pod-somerandomid>`, see no evil, check the ingress logs with `kubectl -n ingress-nginx logs <nginx-ingress-controller-somerandomid>`, see a bunch of backend connection timeouts resulting in 504 responses from nginx, infer that something must have been very very wrong with my policy. Turns out that the `namespaceSelector` for `ingress-nginx` simply did not match any namespace: while there was no typo in the namespace `name` label, a `kubectl describe namespace/ingress-nginx` revealed that the label I was after was `app.kubernetes.io/name: ingress-nginx` and not simply `name: ingress-nginx`. So, corrected version:

```yml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mtg-network
  namespace: mtg
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
      ports:
        - port: 4748
        - port: 8089
  egress:
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - port: 53
          protocol: UDP
```

Now, let's look at the ingress configuration: first we need to trim the routing rules as we don't have 2 tiers but a single server, then we'll have to change port and add some headers to tell nginx to speak websocket to the backend rather than plain http. Servatrice's wiki specifies some nginx headers to add to your config file - in this case they will become a configuration snippet for our Ingress resource, using a `nginx.ingress.kubernetes.io/configuration-snippet` annotation.

The result looks like this:

```yml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: mtg-ingress
  namespace: mtg
  annotations:
    kubernetes.io/ingress.class: "nginx"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      proxy_set_header        Upgrade         $http_upgrade;
      proxy_set_header        Connection      "Upgrade";
      proxy_set_header        X-Real-IP       $remote_addr;
spec:
  tls:
  - hosts:
    - mtg.example.com
    secretName: mtg-tls
  rules:
  - host: mtg.example.com
    http:
      paths:
      - path: /
        pathType: ImplementationSpecific
        backend:
          service:
            name: servatrice
            port:
              number: 4748

```

You might notice that I didn't add in the nginx config snippet all the headers mentioned in servatrice's wiki - turns out that some of them are already set, and setting them twice causes the ingress to fail to start entirely. Once again checking the ingress controller logs supported quick debugging, and I just can't stress enough how important it is to have access to operational logs. Preferably in a centralised, easy to query place.

A preprod environment where to test this stuff without causing disruption would be great too but remember - we're going cheap here, essentially making an intentional tradeoff between cost and availability. Testing is great and as we know from TDD adding tests results in being cheaper than dealing with the sunk cost of fixing more bugs. While the same is true for deployment testing, the code for unit tests is free but the compute resources to support a preprod environment are definitely not, and your tests will only be as good and reliable as your investment in the infrastructure that supports them. TL;DR: go throw some ~love~ money at those flaky integration tests of yours! It will pay off in the long run.

So now we have a complete yml file (piecing all the above together in a single file is left as an exercise for the reader), we can `kubectl apply -f mtg.yml` it to the cluster. Yes, from my laptop's terminal. Yes, I know, this doesn't sound very _DevSecOps_ or _CI/CD_ but let me explain: somewhere there needs to be a cut between where we perform high-privilege operations and where we start restricting permissions and applying least privilege. For me at this point in time, the cut happens at this namespace level. Terraforming DigitalOcean, configuring k8s cluster-wide resources (e.g. IngressController, CertManager, Observabilty...) and initialising and authorising namespaces are my "platform team privileged operations", while deploying a Pod into a namespace is my "delivery team restricted privilege operations". Of course the best would be for a platform team to also practice least responsibility and segregation of duties but, you know, there is a limit of how much of this makes sense to adopt for an individual person doing everything! ¯\\\_(ツ)\_/¯

The last bit I've not covered is how to assign a DNS name to the service - to do this all I need is to create an A record and point it at the Load Balancer's public IP. As I mentioned, I do this with Terraform:

```terraform
data "digitalocean_kubernetes_cluster" "your_cluster_name_here" {
  name = "your_cluster_name_here"
}

provider "kubernetes" {
  host  = data.digitalocean_kubernetes_cluster.your_cluster_name_here.endpoint
  token = data.digitalocean_kubernetes_cluster.your_cluster_name_here.kube_config[0].token
  cluster_ca_certificate = base64decode(
    data.digitalocean_kubernetes_cluster.your_cluster_name_here.kube_config[0].cluster_ca_certificate
  )
}

data "kubernetes_service" "ingress_nginx" {
  metadata {
    name      = "ingress-nginx"
    namespace = "ingress-nginx"
  }
}

data "digitalocean_domain" "example_com" {
  name = "example.com"
}

resource "digitalocean_record" "mtg_example_com" {
  domain = data.digitalocean_domain.example_com.name
  type   = "A"
  name   = "@"
  value  = data.kubernetes_service.ingress_nginx.status.0.load_balancer.0.ingress.0.ip
}

```

## Packaging servatrice

TODO - cover attack surface reduction in Docker here

## Deployment

TODO - cover securitycontext here

## In conclusion

TODO