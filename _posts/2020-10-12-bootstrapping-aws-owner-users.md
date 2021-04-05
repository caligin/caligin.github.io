---
title: "Bootstrapping AWS: Owner users"
author: Foo
layout: post
tags: [AWS, "Security Engineering", Terraform, IAM, 🐇🕳️] 
---

### _Or: "How to Jump in Endless Rabbit Holes and Survive to Tell the Story 🐇🕳️"._

It just happened. Don’t ask me why, I don’t really know either. But woke up one morning and decided to prepare for the [AWS Security Specialism](https://aws.amazon.com/certification/certified-security-specialty/) certification. Three hours later I had purchased an online course subscription, set a whole bunch of dodgy domains to “trusted” in [NoScript(https://noscript.net/) to be able to play videos, and of course I need an AWS playground to tinker along. Before using the account(s) I needed to lay  some groundwork , on top of my head that  looked like:

- "owners" IAM users for humans
  - MFA enforced
  - need to MFA `AssumeRole` to do anything privileged
- CloudTrail enabled
- Multi-account setup
- AWS Organizations enabled
- Service Control Policies for preventative controls

This sounds easy enough right? But of course nothing in computering goes your way on the first try, and neither on the 7th... On the 18th attempt it's 5AM on a Friday after trying all week sacrificing the little personal time I have, any form of human interaction and that pot of yoghurt asking for mercy in the back of the fridge, it now finally works - kinda.. Did I tell you I hate computers? But I'll note down my thought process on this journey so you don't have to hate them too.

I don't want this to be one more "howto" guide, the interwebz provides. What I want to focus on are the constraints and tradeoffs and how they lead to an implementation decision, so here we go:

## Scope & Acceptance Criteria

Out of the various items listed above, the first one that you would encounter setting up a new AWS account is to create privileged users to avoid using `root`. Creation of initial users is the minimal set of operations that has to be done with the root account, so that's gonna be the scope for the first story. Moreover, thinking a few steps ahead, the future looks like a multi-account organisation where the main account only holds users and org settings, so creating users is as far as we should go before creating more accounts.

What does good look like? I'd say the usual suspects:
- MFA enforced, because no one is immune from phishing
- privileged actions require MFA-protected `AssumeRole` so access key theft does not cause instapwnage
- obtaining your IAM User is a self-service experience. The current standard is that someone with existing privileges gets to create an IAM user, set its initial password and email it to its new owner, and it’s 2020, and this kinda sucks.

## Constraints & Engineering Requirements

Besides the functional goal, there's a couple of other things that need to be kept  in mind when building this. Some are constraints, others are things that should definitely be done immediately, because previous experience suggests that skipping  it now creates technical debt. This debt might not be perceived until much later, but having had the experience of missing out on it previously we can avoid sucking at it again.

Here is my laundry list for today:
- Has to be cheap. For "groundwork" stuff that I won't be turning on and off to save, it has to be *really* cheap. Luckily IAM Users  come for free.
- Must be IaaC. For me this meansTerraform, unless something is not supported by the AWS provider or _really_ needs to be manual.
- Should have non-local tfstate. And I say should because I'm not up to date on the latest options (more on this later).
- ~~Must be automated~~. I would normally say automate all the things but this is an exception. Again, more on this later.

Because of the cost constraints, I decided not to adopt [Control Tower](https://aws.amazon.com/controltower/), it looked like an excellent option to start with a good baseline, but £££. Plus, it doesn't seem to be supported by Terraform to date (Oct 2020).

The point about non-local tfstate led me into a rabbithole about the alternatives and eventually back to square 0: local state `#dealwithit`. Reasonably standard tradeoff justification: state being local is likely to cause apply conflicts but being only 2 of us and the owner users being a low-change tf stack it probably won't be a problem.

## The result

Looks like this, in a single Terraform stack:

![diagram](/assets/img/aws-bootstrap.png "diagram")

What have we got? First: two users. They have a login profile and get an auto generated password, both gpg-encrypted with the same key that I generated fresh for this on my laptop. This isn't great, I would have really liked some sort of invite link but I couldn't find a viable alternative. As per the gpg keys, my main one incurred in some subkeys Terraform issue and Panda (user number `0x02`) didn't have one at hand so being both in the same room we decided that the risk window was small enough that using a purposedly-generated key was fine. We shared the initial passwords via [Signal](https://signal.org/) desktop with disappearing messages.

The users are part of an `owners` group. A policy attached to the group enforces setting up MFA and prevents anyone doing anything until that's present, and allows users to self-manage their IAM credentials and settings. The policy is a modified down version of [the one described here](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_examples_aws_my-sec-creds-self-manage.html), with a few things removed and the paths adjusted: users, group and policies are all namespaces under the `/owners/` path, so that as the complexity of the setup grows in the future, it will be easier to perform segmentation. One annoying thing remains  unsolved: after setting up MFA for the first time via the web console, users will have to log out and log in again for the policy variable `aws:MultiFactorAuthPresent` to be populated. I have no clue what to do about this.

Important detail to note about user settings and IAM policies is that password reset at first login *must not* be enforced: it clashes with MFA setup enforcement and makes it impossible to do the first password reset at all.It's In the AWS guide linked above it’s pointed out that without `iam:ChangePassword` in the `NotActions` stanza users won't be allowed to change password before setting MFA, resulting in the users being locked out. But adding it allows the password to be changed without MFA in session, effectively allowing a stolen or leaked AccessKey to be used for account takeover! Having to choose, I think not enforcing immediate password rotation is way less exposure, and decided to accept that risk: I'd insist to enforce policies when scaling up users, as you can't rely on everyone to do the right thing during onboarding, but being just the two of us this isn’t worth the cost and complexity of doing something clever with lambdas.

The third main component of the stack is the `owners` IAM role. The role has attached the IAM-managed policies `AdministratorAccess` and `job-function/Billing` to perform any administration function instead of `root`. Being the highest level of privilege, the trust policy of the role requires MFA to be present in session, and allows assuming only from the two named users specifically, not from the entire `owners` group. Why? just as an additional layer of protection from escalation: in the future, if there's any space for an attacker to add themselves to the `owners` group, that would still not be enough to assume full administrative powers.

## The automation

The tool of choice is [Terraform CLI](https://www.terraform.io/docs/cli-index.html), defining a single stack. I would have liked for the state to be remote: the problem of bootstrapping tfstate is well known, but given that my main infrastructure lives on [DigitalOcean (referral link)](https://m.do.co/c/0b6a6e56d149), I thought I could use that to break the usual 🐔&🥚 problem. That didn't work: an alternative would have been [Terraform Cloud](https://www.terraform.io/docs/cloud/index.html), but that would imply storing root (or root-equivalent) credentials on tfcloud, that doesn't sound good to me. I'm happy to trust cloud platforms with credentials for automation, but only with restricted privileges and bulkheading in place.

Another common problem of Terraform is the version/state compatibility. This is a problem that I decided to solve with a note in `README.md` about always using latest rather than automating it. I find wrapper scripts rather cumbersome, and I'm sure there's tooling out there to make this better but I'm not familiar enough to adopt any just yet.This bootstrap stack, or maybe a couple more to enable automation, are not enough to cause a real problem with version consistency - yet.

Couple of other things, a `Makefile` gives a minimal wrapper to running [`tfsec`](https://github.com/tfsec/tfsec) and decrypting the stack gpg-encrypted outputs, so I don’t have to remember command flags and output encodings. As per `terraform init`, it’s simply mentioned in the `README.md` as this stack doesn't need any init var..

As per running the stack with `root`, in reality I cheated: my AWS account existed for a few years and I already had a manually created IAM user with badly assigned superpowers, so that's what I used and left `root` untouched. Yeah, I know, that's not fair but, hey, when life gives you lemons... [have your engineers invent a combustible lemon](https://en.wikiquote.org/wiki/Portal_2#Cave_Johnson).

## In conclusion

The minimal Terraform stack to bootstrap an AWS account is relatively simple: just a couple users and policies, leveraging articles published by AWS. To set yourself up for success and avoid the costs of retrofitting security down the line, it's worthwhile to not skimp on MFA and require MFA-protected `AssumeRole` for top tier privileges. A couple of other battles in the IAM policy and Terraform automation space are simply not worth the fight in the context of a single (or a handful of) stack(s), but worth revisiting when planning for scale.

Happy tinkering!

## The rabbit holes 🕳️🕳️🐇🕳️

You thought that was easy? Well, it took me *over a bloody week* to write this stack, working on it all evening and night. Part of that is that I simply cannot accept that something is a bit rubbish without going on long detours finding alternatives, while that's my own problem, other things happened simply because _"no plan survives contact with a computer"_ [citation needed]. Read on if you want to dive into the rabbit holes with me, you won’t believe number -0xa:

### Automating Terraform

So far I've written a handful of Terraform stacks but I've not looked much into the automation around it. My experience from work is limited to reasonably simplistic setups with Terraform CLI calls straight from some CircleCI, ConcourseCI and the likes, but I've yet to  take a look at what's available in 2020, like the newer versions of Terraform released and products like Terraform Cloud and similar in the market.

Recently all the automation I build is on [GitHub Actions](https://github.com/features/actions) as it's a seamless experience to use for private repositories already on GitHub. Actions comes with some pre-packed templates and that includes Terraform, specifically with Terraform Cloud. I dedicated some time reading into it and figuring out how it works, and whether it's worth using it in combination with Actions or not.

In conclusion, whichever way, it means that a cloud provider has credentials with enough privilege to create resources. But this stack is meant to be executed by `root`! That's too much exposure to be comfortable with: losing `root` means complete compromise of the AWS environment. And what about priming an IAM entity for automation *first*? Well, the users created by this stack are the break-glass-scenario superadmins meant to govern everything else and  to be able to recover from incidents. Limiting the ability to update owner users to only root and themselves reduces the attack surface for this incredibly powerful escalation vector. SaaS providers have top-notch security engineers but still at the end of the day mistakes and breaches happen. When crossing a trust boundary is always good caution to apply reduced privileges as appropriate based on risk and benefits.

In this case, there's not much benefit to automate the application of a stack that will only need to be run a couple times (spoiler alert: a couple in this case is spelled with several zeroes), while the risk is complete compromise of the AWS environment. Not worth it.

Looking a few stories in the future, everything  will be automated with CI and Terraform versions will be pinned in CI jobs definitions. Although, I must admit, going through commit, push and CI wait times is a painful experience and I have no clear plan yet on how to address the need for faster feedback during stack development.

### Terraform State of DigitalOcean

As I mentioned, my main infra runs on [DigitalOcean (referral link)](https://m.do.co/c/0b6a6e56d149), where I have the tiniest k8s cluster and private image registry. On DO, Spaces is like S3 but prices as a single fee of 5 USD/mo rather than on-demand. Having a private registry requires Spaces to be already active, so using it for anything else will not incur additional expense. Terraform doesn't support DO directly as a backend, but Spaces is S3-compatible [and can be used as an S3 Terraform backend with some params tinkering](https://dev.to/aleixmorgadas/storing-terraform-state-in-digital-ocean-space-3a97). So far so good.

To access Spaces DO offers an AccessKey and SecretKey exactly like AWS, but how does Terraform access the bucket? Those keys would need to be called `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` to be picked up, but then they would be used to perform *actual* AWS operations too, and of course these keys are not actually AWS keys. So much fail.

So local state it is, this is not worth it. I think that an alternative would be specifying the keys straight into the provider configuration or with a partial initialisation, but I'm straight out unwilling to write secrets to a file inside of a repo.

### GPG encrypted passwords

My main GPG key has the secret component offline and uses subkeys, stored on a Yubikey. So far so good. I've been running this setup for years now without too much trouble (in relative, GPG-contextual terms), including using that same key, via [Keybase](https://keybase.io/caligin), for a `aws_iam_user_login_profile#pgp_key` parameter. And that's exactly what I did this time, expecting the usual: software that tries to encrypt against my public key would select my encryption subkey instead and encrypt with that. Wrong.

```
terraform output | grep initial | cut -d' ' -f3 | base64 -d | gpg --decrypt -v
gpg: public key is 0x7AD2E918B3D5FFB7
gpg: encrypted with 4096-bit RSA key, ID 0x7AD2E918B3D5FFB7, created 2015-06-03
      "Foo Meden (0xf00) <foo@anima.tech>"
gpg: decryption failed: No secret key
```

It seems like Terraform decided that it really wants to use my main key instead. I thought that it might have been a problem with having a lot of expired subkeys still lying around, and removed them. Or maybe it was due to my Keybase not being updated for a while. Neither worked. Then I decided to try export only the subkey's public component instead of the bundle with everything, to find out that [you simply can't](https://security.stackexchange.com/questions/74067/is-it-possible-to-export-a-gpg-subkeys-public-component). My attempt to use `gpgsplit` to do this manually at 3AM only resulted in wasting the entire following evening trying harder, and getting nowhere.

Neither Terraform nor the AWS provider seemed to have a bug open for this, so I wanted to see what library they use to handle gpg and see whether there's a known issue there. What I found out instead is that [the piece of logic that selects keys is in the AWS provider itself](https://github.com/terraform-providers/terraform-provider-aws/blob/39de967ca0e41f7848dd26441355ff6f162db0b2/aws/internal/encryption/encryption.go#L38 ), selects the first key available that is flagged for encryption usage. Unfortunately, my primary key is flagged as such.

At this point I pretty much gave up and decided to just get the initial passwords out unencrypted. They will only live for a short time and if my laptop is compromised we have bigger problems in the chain of trust than just the passwords. But again, no, encrypting with gpg is *mandatory*. That is actually a good default and I'm grateful for that, except that in this specific case it turned out being rather frustrating.

So, whatever, I just created a fresh key. Default params, short lifetime, only exist on my laptop, no distribution. If I ever need to rotate these passwords I can just generate a new throwaway key again. Ephemeral keys FTW.

This whole encryption rabbithole has been truly bonkers.

### It's 2020 and I don't want to send pre-generated passwords to people

So what about identity providers! Maybe I can set up AWS federation with something where users can generate their own identities, instead of having the annoying step of passwords being revealed, albeit briefly, to the ev1l h4cker 4dm1n? In some work contexts I've been using [Okta](https://www.okta.com/) SAML federation and the experience is great. I don't have an Okta subscription, but mapping to GitHub organisation and teams would indeed be lovely. Except that GitHub does not support OIDC, nor SAML. Only Oauth2, that is not enough for [federated logins for AWS](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers.html).

I have an [Auth0](https://auth0.com/) account that I played with in the past, and while documentation available seems to mainly explain how to setup integration with Cognito pools, [a SAML-based integration seems to be possible](https://auth0.com/docs/integrations/how-to-set-up-aws-for-delegated-authentication). But in between learning how to set it up, I thought: wait how do I create users on Auth0? Well in the simplest form... assigning them a pre-generated password.

(╯°□°）╯︵ ┻━┻

Damn 2020.

In fairness, I suspect that ultimately setting up SAML federation and then some other Auth0 -> ? connection to get the user identities might be a thing, but after spending enough time on this I just unwound the stack and went back to the main problem.

### You thought you did it

It had been 4 days until 2.30AM and I really needed to move on. Finally, I got to create a test user I can successfully login with, change pwd, self-assign a TOTP, go through the misery of having to reauth to be allowed to do anything at all and finally fumble with config files and profiles to check console access. After creating access key and finding my MFA ARN with `aws iam list-virtual-mfa-devices` it looks something like:

```
[profile test]
output = json
region = eu-west-2

[profile testowner]
source_profile = test
role_arn = arn:aws:iam::1234:role/owner
mfa_serial = arn:aws:iam::1234:mfa/test-admin
```

`aws --profile testowner iam list-users` prompts for mfa. win.

Amazewows. Did it. Sleep.

Day after: replace the test user with real usernames, `terraform apply`, login, get prompted for a password change... `Password does not conform to the account password policy.`. Wat iz dis even. Past the first moment of angry stupor, debugging: the new password is *very* compliant to the policy (that, I realise only later, is not being displayed), so it must be a problem with permissions. I won't go in the details again as it's been explained above, but basically this is the problem with requiring users to set up MFA before doing anything else including a password change, but also enforcing a password change at first login.

I have no idea how I tested this successfully. I might actually have not enforced password reset on the test user, or used a slightly different policy. It was late, and I did a few adjustments in between that looked innocuous. Of course that wasn't the case.

Don't do a me, remember retesting, always.

## In *actual* conclusion

This is why spikes are timeboxed and it's recommended to move on when stuff doesn't work at the third (or maybe second) try. But not all rabbitholing is bad! Going through this I actually learned a lot, and all is valuable and ultimately grows my knowledge in the grand scheme of things (`overall://`). I won't call out explicitly all the things I learned in a list but that definitely includes having an overview of a bunch of SaaS products and AWS services, some deeper gpg packeting, some federation mumbo jumbo and a few other things.

It's about the journey, not the destination.
