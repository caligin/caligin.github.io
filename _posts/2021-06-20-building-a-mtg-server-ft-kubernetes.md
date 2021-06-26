---
title: "Building a Magic: the Gathering server (ft. Kubernetes security)"
author: Foo
layout: post
tags: [k8s, "Security Engineering"]
ocb: '{{'
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
  resources: ["deployments", "replicasets", "pods", "services", "configmaps"]
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

The security inclined would indeed notice that this template misses on an important control in a k8s namespace: a default NetworkPolicy. It's an unfortunate default, but by default in a k8s cluster there is no network restriction whatsoever around what can communicate where, even across namespaces. In order to do so, the recommendation is to always start by adding a policy that default denies all egress and egress - then add more policies to allow the necessary traffic.

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

Then, what do we need to allow? For sure ingress traffic needs to be allowed from the Ingress Controller namespace to forward traffic to the servatrice websocket port (4748), and we'll allow the Pod to contact k8s's internal DNS, even if I suspect it's not strictly needed in this case. Lastly, and I discovered this only a few TLS failures later, we also need to allow the Ingress Controller to forward to Cert-manager to solve an [ACME HTTP challenge](https://cert-manager.io/docs/tutorials/acme/http-validation/).

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

A preprod environment where to test this stuff without causing disruption would be great too but remember - we're going cheap here, essentially making an intentional tradeoff between cost and availability. Testing is great and as we know from TDD adding tests results in being cheaper than dealing with the sunk cost of fixing more bugs. While the same is true for deployment testing, the code for unit tests is free but the compute resources to support a preprod environment are definitely not, and your tests will only be as good and reliable as your investment in the infrastructure that supports them. TL;DR: go throw some ~~love~~ money at those flaky integration tests of yours! It will pay off in the long run.

So now we have a complete yml file (piecing all the above together in a single file is left as an exercise for the reader), we can `kubectl apply -f mtg.yml` it to the cluster. Yes, from my laptop's terminal. Yes, I know, this doesn't sound very _DevSecOps_ or _CI/CD_ but let me explain: somewhere there needs to be a cut between where we perform high-privilege operations and where we start restricting permissions and applying least privilege. For me at this point in time, the cut happens at this namespace level. Terraforming DigitalOcean, configuring k8s cluster-wide resources (e.g. IngressController, CertManager, Observability...) and initialising and authorising namespaces are my "platform team privileged operations", while deploying a Pod into a namespace is my "delivery team restricted privilege operations". Of course the best would be for a platform team to also practice least responsibility and segregation of duties but, you know, there is a limit of how much of this makes sense to adopt for an individual person doing everything! ¯\\\_(ツ)\_/¯

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

Alright now that the platform bits are configured and ready to host a service, we need to package servatrice nicely and slot it into the namespace. Servatrice comes with its own `Dockerfile`, which is the recommended way of building the server. The simplest approach would indeed be to just clone the Cockatrice repo, build the Docker image, push to repo and tell k8s to deploy the new version. But would that be ok? Looking at the dockerfile (at the time of writing), it seems that:
- the container runs servatrice as root
- it's based on ubuntu but not the latest LTS
- ubuntu LTS version is not pinned
- installs developer tools to build and leaves them in the container

And that's fine, but some of this is attack surface that can be easily reduced. Moreover, I'll be versioning the artifacts I build, and deploy to k8s pinning a specific version: if I build straight off servatrice, which version am I going to tag? Servatrice's git hash would be a good first guess, but what if I change anything else in the repo? That might trigger a rebuild, that can pull a different version of the base ubuntu image and packages from apt, and then get tagged with the same tag that existed before. Having confidence on build identifiers being immutable (as much as they can) means that there's less cognitive load to consider when thinking about what software is running in the cluster over time, so let's try address this: we can start from a build of upstream, pinned and then tagged on upstream's git tag, and only triggered on a changing git version pin (ish, but close enough). This translates in a single GitHub Actions workflow as follows:

```yml
name: Servatrice Upstream

on:
  push:
    branches:
      - main
    paths:
      - ".github/workflows/servatrice-upstream.yml"

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v2
      with:
        repository: Cockatrice/Cockatrice
        ref: 2021-01-26-Release-2.8.0
    - name: Install doctl
      uses: digitalocean/action-doctl@v2
      with:
        token: ${{page.ocb}} secrets.DIGITALOCEAN_ACCESS_TOKEN }}
    - name: login to registry
      id: do-registry
      run: "echo \"::set-output name=password::$(doctl registry docker-config --read-write --expiry-seconds 3600 | jq -r '.auths[\"registry.digitalocean.com\"].auth' | base64 -d | cut -d: -f 1)\""
    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v1
    - name: Login to DOCR
      uses: docker/login-action@v1
      with:
        registry: registry.digitalocean.com
        username: ${{page.ocb}} steps.do-registry.outputs.password }}
        password: ${{page.ocb}} steps.do-registry.outputs.password }}
    - name: Generate meta
      id: meta
      run: |
        DOCKER_IMAGE=registry.digitalocean.com/<YOUR_REGISTRY_NAME_HERE>/servatrice-upstream
        UPSTREAM_VERSION=v2.8.0
        TAGS="${DOCKER_IMAGE}:${UPSTREAM_VERSION}"
        echo ::set-output name=tags::${TAGS}
        echo ::set-output name=created::$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    - name: Push to DOCR
      uses: docker/build-push-action@v2.5.0
      with:
        context: .
        file: ./Dockerfile
        tags: ${{page.ocb}} steps.meta.outputs.tags }}
        push: true
        labels: |
          org.opencontainers.image.source=${{page.ocb}} github.event.repository.clone_url }}
          org.opencontainers.image.created=${{page.ocb}} steps.meta.outputs.created }}
          org.opencontainers.image.revision=${{page.ocb}} github.sha }}

```

Now we can use upstream as a base to derive our own image and tackle some surface reduction. Looking in servatrice's install scripts it's easy to find out that the binary installs in (unsurprisingly) `/usr/local/bin/`, so we can start by copying it over from a version-pinned upstream into a version-pinned `ubuntu:latest` and drop privileges.

```Dockerfile
FROM registry.digitalocean.com/<YOUR_REGISTRY_NAME_HERE>/servatrice-upstream:sha256:abcdef1234YOUR_SHA_HERE as upstream

# ubuntu:focal-20210416
FROM ubuntu@sha256:adf73ca014822ad8237623d388cedf4d5346aa72c270c5acc01431cc93e18e2d

COPY --from=upstream /usr/local/bin/servatrice /usr/local/bin/servatrice

RUN groupadd -r servatrice -g 1000 && useradd --no-log-init -r -s /bin/false -u 1000 -g servatrice servatrice && mkdir /home/servatrice && chown servatrice. /home/servatrice
USER servatrice
WORKDIR /home/servatrice
EXPOSE 4748
ENTRYPOINT [ "/usr/local/bin/servatrice" ]

```

This should do exactly what I wanted, except that when trying it out, it crashes due to missing libraries. Well of course, I copied the binary over to leave behind the compiletime dependencies... but as a result I left behind the runtime dependencies too. The instinct is to reproduce the `RUN apt-get install ....` step from upstream, but with runtime dependencies only. Turns out though that this is where the decision of upgrading Ubuntu backfires: only newer version of some libraries are available, but the binary has been linked to the specific versions available in Ubuntu Bionic. Aw, `snap`! (pun intended).

So now the right thing would likely be either starting over and compiling in Ubuntu Focal, or using Bionic as the runtime. But no, what I thought of doing instead is to get a list of the libraries needed and where they are:

```shell
$ docker run -ti --rm --entrypoint /bin/bash servatrice-upstream:v2.8.0
root@f2d9aa4aed4f:/home/servatrice# ldd /usr/local/bin/servatrice
  linux-vdso.so.1 (0x00007ffe56f67000)
  libQt5Sql.so.5 => /usr/lib/x86_64-linux-gnu/libQt5Sql.so.5 (0x00007f481bd47000)
  libQt5WebSockets.so.5 => /usr/lib/x86_64-linux-gnu/libQt5WebSockets.so.5 (0x00007f481bb19000)
  libprotobuf.so.10 => /usr/lib/x86_64-linux-gnu/libprotobuf.so.10 (0x00007f481b6c0000)
  libpthread.so.0 => /lib/x86_64-linux-gnu/libpthread.so.0 (0x00007f481b4a1000)
  libQt5Network.so.5 => /usr/lib/x86_64-linux-gnu/libQt5Network.so.5 (0x00007f481b115000)
  libQt5Core.so.5 => /usr/lib/x86_64-linux-gnu/libQt5Core.so.5 (0x00007f481a9ca000)
  libstdc++.so.6 => /usr/lib/x86_64-linux-gnu/libstdc++.so.6 (0x00007f481a641000)
  libgcc_s.so.1 => /lib/x86_64-linux-gnu/libgcc_s.so.1 (0x00007f481a429000)
  libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f481a038000)
  libz.so.1 => /lib/x86_64-linux-gnu/libz.so.1 (0x00007f4819e1b000)
  /lib64/ld-linux-x86-64.so.2 (0x00007f481c3ff000)
  libicui18n.so.60 => /usr/lib/x86_64-linux-gnu/libicui18n.so.60 (0x00007f481997a000)
  libicuuc.so.60 => /usr/lib/x86_64-linux-gnu/libicuuc.so.60 (0x00007f48195c2000)
  libdouble-conversion.so.1 => /usr/lib/x86_64-linux-gnu/libdouble-conversion.so.1 (0x00007f48193b1000)
  libdl.so.2 => /lib/x86_64-linux-gnu/libdl.so.2 (0x00007f48191ad000)
  libglib-2.0.so.0 => /usr/lib/x86_64-linux-gnu/libglib-2.0.so.0 (0x00007f4818e96000)
  libm.so.6 => /lib/x86_64-linux-gnu/libm.so.6 (0x00007f4818af8000)
  libicudata.so.60 => /usr/lib/x86_64-linux-gnu/libicudata.so.60 (0x00007f4816f4f000)
  libpcre.so.3 => /lib/x86_64-linux-gnu/libpcre.so.3 (0x00007f4816cdd000)

```

Aaaaaaaaand slap a bunch of `COPY` instructions in my Dockerfile!

```Dockerfile
...

COPY --from=upstream /usr/local/bin/servatrice /usr/local/bin/servatrice

COPY --from=upstream /usr/lib/x86_64-linux-gnu/libQt5Sql.so.5 /usr/lib/x86_64-linux-gnu/libQt5Sql.so.5
COPY --from=upstream /usr/lib/x86_64-linux-gnu/libQt5WebSockets.so.5 /usr/lib/x86_64-linux-gnu/libQt5WebSockets.so.5
COPY --from=upstream /usr/lib/x86_64-linux-gnu/libprotobuf.so.10 /usr/lib/x86_64-linux-gnu/libprotobuf.so.10
COPY --from=upstream /usr/lib/x86_64-linux-gnu/libQt5Network.so.5 /usr/lib/x86_64-linux-gnu/libQt5Network.so.5
COPY --from=upstream /usr/lib/x86_64-linux-gnu/libQt5Core.so.5 /usr/lib/x86_64-linux-gnu/libQt5Core.so.5
COPY --from=upstream /usr/lib/x86_64-linux-gnu/libicui18n.so.60 /usr/lib/x86_64-linux-gnu/libicui18n.so.60
COPY --from=upstream /usr/lib/x86_64-linux-gnu/libicuuc.so.60 /usr/lib/x86_64-linux-gnu/libicuuc.so.60
COPY --from=upstream /usr/lib/x86_64-linux-gnu/libdouble-conversion.so.1 /usr/lib/x86_64-linux-gnu/libdouble-conversion.so.1
COPY --from=upstream /usr/lib/x86_64-linux-gnu/libglib-2.0.so.0 /usr/lib/x86_64-linux-gnu/libglib-2.0.so.0
COPY --from=upstream /usr/lib/x86_64-linux-gnu/libicudata.so.60 /usr/lib/x86_64-linux-gnu/libicudata.so.60

...
```

If this looks like a horrid hack that's because, well, it is indeed. Now, I *could* conjure an excuse for this and give it some spin, but really, at a certain point I decided that I was on a good track overall to make it work and got sloppy rather than pivoting approach.

I really wanted to get to a working result before revisiting this! So container done, let's build it and push it up to the registry. I'll spare you the GitHub workflow as it's exactly as the one above, except that it doesn't clone a different repo and tags the image with `SHA_TAG=sha-${GITHUB_SHA::7}` rather than a static version from upstream.

## Deployment

Time to deploy this! Let's start with preparing the workflow though: you remember the `mtg` namespace that we created in k8s before? It had a `ServiceAccount` configured in it, time to grab some credentials for it. I have a bash script for this that is fairly crude but does the job (I think I made it taking some examples from Spinnaker and modifying from there??):

```bash
#!/bin/bash
namespace=$1
serviceaccount=$2
if [ "$1" == "" ] || [ "$2" == "" ] ; then
    echo "generates a base64-encoded kubeconfig to use in the kubectl-action github action (https://github.com/marketplace/actions/kubectl-action)"
    echo "usage: $0 <namespace> <serviceaccount>"
    exit 1
fi

secret=$(kubectl get serviceaccount --namespace ${namespace} ${serviceaccount} -o jsonpath="{.secrets[0].name}")
token=$(kubectl get secret --namespace ${namespace} ${secret} -o jsonpath="{.data.token}" | base64 --decode)
context=$(kubectl config current-context)
tmp_kubeconfig=$(mktemp)

kubectl config view --raw > ${tmp_kubeconfig}
kubectl --kubeconfig ${tmp_kubeconfig} config unset users
kubectl --kubeconfig ${tmp_kubeconfig} config set-credentials ${context}-${namespace}-${serviceaccount} --token ${token}
kubectl --kubeconfig ${tmp_kubeconfig} config set-context ${context} --namespace ${namespace} --user ${context}-${namespace}-${serviceaccount} --token ${token}
kubectl --kubeconfig ${tmp_kubeconfig} config view --raw | base64 -w0

```

The output is a big base64 encoded blob that we can copypaste right into a GitHub Actions Secret called `KUBE_CONFIG`. Now that we have this in place, the plan is reasonably simple: extend our GHA workflow to create a k8s `Deployment`, wait for its rollout and rollback if it fails. All of this in a separate job from the build steps at least - otherwise a build failure risks to trigger a rollback (at least, the way I'm doing it on fail with a `if: ${{page.ocb}} failure() }}` condition, which is job-scoped). 

```yml
  deploy:
    runs-on: ubuntu-latest
    needs: build

    steps:
    - uses: actions/checkout@v2
    - name: Template deployment file with git tag
      run: sed -i "s/GIT_TAG/sha-${GITHUB_SHA::7}/" deployment.yml
    - uses: danielr1996/kubectl-action@1.0.0
      name: Deploy
      with:
        kubeconfig: ${{page.ocb}} secrets.KUBE_CONFIG }}
        args: apply -f deployment.yml
    - uses: danielr1996/kubectl-action@1.0.0
      name: wait for rollout
      with:
        kubeconfig: ${{page.ocb}} secrets.KUBE_CONFIG }}
        args: rollout status deployment/servatrice --timeout 60s
    - name: Rollback on failed acceptance
      if: ${{page.ocb}} failure() }}
      uses: danielr1996/kubectl-action@1.0.0
      with:
        kubeconfig: ${{page.ocb}} secrets.KUBE_CONFIG }}
        args: rollout undo deployment/servatrice

```

What about that `sed` step then? Well that's the simplest way I could think of templating a deployment descriptor file with the image version we just built in the previous job. Let's look at this deployment file then:

```yml
apiVersion: v1
kind: Service
metadata:
  name: servatrice
spec:
  ports:
  - port: 4748
    targetPort: 4748
  selector:
    app: servatrice
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: servatrice
spec:
  selector:
    matchLabels:
      app: servatrice
  replicas: 1
  template:
    metadata:
      labels:
        app: servatrice
    spec:
      containers:
      - name: servatrice
        image: registry.digitalocean.com/<YOUR_REGISTRY_NAME_HERE>/servatrice:GIT_TAG
        args: ["--config", "/config/servatrice.ini", "--log-to-console"]
        ports:
        - containerPort: 4748
        volumeMounts:
        - name: servatrice-config
          mountPath: /config
          readOnly: true
        securityContext:
          runAsUser: 1000
          runAsGroup: 1000
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          readOnlyRootFilesystem: true
      volumes:
      - name: servatrice-config
        configMap:
          name: servatrice-config
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: servatrice-config
data:
  servatrice.ini: |
    [server]
    name="My MTG"
    id=1
    number_pools=0
    websocket_number_pools=1
    websocket_host=any
    websocket_port=4748
    writelog=0
    [authentication]
    method=password
    password=<HARDCODED_PASSWORD_HERE>
    regonly=false
    [security]
    enable_max_user_limit=true
    max_users_total=10
    max_users_per_address=2

```

Most of it is nothing special! Just a pod listening on a port. And exactly because it's doing nothing special, and we baked some privilege dropping in the Dockerfile earlier, we can enable some nice options on the `securityContext` to prevent some forms of privilege escalation or container breakout! And we can create servatrice's configuration file via a `ConfigMap`: with it we can disable the tcp plain listener, limit the total number of users and configure our shared password. I would normally have a panic attack at a password hardcoded in git but in this case considering mitigations, exposure of the shared secret and possible impact if it's stolen... I can only say "whatevs!". But again, this is a homemade effort for personal use with friends, don't make the same consideration for anything serious or business. For how many mitigations you can add, it's still hard to defend a hardcoded credential during an audit or, worse, explain it after a breach.

With this heap of yml in place, the other heap of yml (the workflow one) can pick it up and deploy our server. Time to grab your clients and try a connection to `mtg.example.com` on `443`!

## In conclusion

Servatrice has been our guinea pig for this story but what we covered is, end to end, how to grab a piece of server software off the internet and deploy it in your Kubernetes cluster with some added security mitigations for good measure.

In reality there is more we can do - address my horrid hack with libraries, add Dependabot, use an actual k8s `Secret` (instead of hardcoding that password and making it sound like I can make sensible risk assessments lol), looking into AppArmor and other extra mitigations reported by `kubeaudit`. But for today, I'll stop here - and go play some MTG games instead!
Hope you will find this journey useful.

Happy hacking!