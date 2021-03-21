---
permalink: /projects
---

stuff I've worked on, in no particular order:

# actual-cookbook and cookbookc

[Actual food recipes](https://github.com/caligin/actual-cookbook), nothing to do with infrastructure provisioning.

Available on [cookbook.protocol.kitchen](https://cookbook.protocol.kitchen). Cookbookc is a rust tool that reads recipes structured in yaml format and outputs consistently formatted markdown or json to include and use in other projects.

Maintained every now and then with new recipes and small improvements.

# still

[The Log Still](https://github.com/caligin/still/), a bare-bones, lightweight structured log search tool.

I needed some lightweight log aggregation and search functionality, but deploying a FLK stack on my tiny DigitalOcean Kubernetes cluster crashed the whole thing.
I took the chance to learn some Rust and play around with compiler compilers.

Usable with barebones features and some rough edges.

# tinytypes

Using `Strings` for any representation of IDs in JVM languages leads to easy type confusion, or same with numerical types that represent different things that are all numbers but should never be mixed together.

TinyTypes is the practice of wrapping simple types in their own named class to help the compiler help you use the right number in the right method call.

This library suite provides support for creating TinyTypes with a little boilerplate done for you, and provides integrations to make them effective in common frameworks.

Current version is stable, will expand support to SpringFramework "Very Soon™"