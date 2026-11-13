# What is Livery

Livery is the software layer that lets a company's services talk to the
web: it receives requests from browsers, mobile apps and other programs,
hands them to the company's own code, and sends the answers back. This
page explains what it does and why it matters, without code. Read it if
you decide whether to use Livery, fund work on it, or run a team that
builds on it.

## The problem

Every online service needs a web layer. In the Erlang world, where many
of the most reliable systems run (telephone switches, messaging services
with hundreds of millions of users), building one today means putting
together a dozen separate libraries: one for each version of the web's
protocol, one for real-time updates, one for sign-in, one for
monitoring, one for AI agents. Each comes with its own way of working,
its own release schedule and its own gaps. The newest version of the
protocol, HTTP/3, is missing or still experimental in the usual
choices.

The result is more code to maintain, more people needed to maintain it,
and features that other platforms take for granted arriving late.

## What Livery does

Livery puts that layer in one package.

- **Every version of the web protocol, from the same code.** A team
  writes its service once. Livery serves it over HTTP/1.1, HTTP/2 and
  HTTP/3 at the same time, and tells browsers that the newest one is
  available so they can switch to it.
- **Faster on mobile and poor networks.** HTTP/3 connects in fewer round
  trips, and a lost packet slows down only the request it belongs to,
  not every request on the connection. Users on phones and weak
  connections feel the difference most.
- **Real-time features.** Live updates, chat, notifications and
  streaming answers (such as text from an AI model, word by word) work
  the same way on every protocol.
- **Ready for AI agents.** Livery speaks the Model Context Protocol (MCP)
  and Agent-to-Agent (A2A), the two common ways for AI assistants and
  agents to call a service. A company can open its tools to AI agents
  on the same server, with the same security, instead of running a
  second system for it.
- **Security included.** Sign-in with an identity provider (OpenID
  Connect), passkeys, one-time codes, access tokens, client
  certificates and signed sessions are part of the package and follow
  the published standards. Each one is listed in the project with the
  standard it implements.
- **Visibility in production.** Every request can be traced and
  measured with the OpenTelemetry conventions that common monitoring
  tools read.
- **Calling other services too.** The same model works for the requests
  a service sends out, with timeouts, retries and load balancing in one
  place.

## Why it matters

- **For a manager:** one dependency instead of a dozen, one way of
  working for the whole team, and less code of your own to maintain.
  Features such as HTTP/3, passkeys or AI-agent access become settings,
  not projects.
- **For an investor:** Erlang and its virtual machine (the BEAM) run
  systems that must not stop, and companies that choose them keep them
  for years. Livery gives that platform a modern web layer it was
  missing, including HTTP/3 and AI-agent protocols, under a permissive
  open-source license.
- **For the people who use the service:** pages and apps that answer
  faster, especially on mobile, and sign-in methods such as passkeys
  that are both easier and safer than passwords.

## Where it stands

- **Open source** under the Apache 2.0 license, which allows commercial
  use. It is published on hex.pm, Erlang's package registry.
- **Young.** The current version is 0.13. The design is settled and
  tested on every protocol, but the programming interface can still
  change between versions; each change is listed in the CHANGELOG.
- **Tested against itself.** One test suite runs the same checks over
  every protocol and fails if any of them behaves differently.
- **Already used** by companion libraries for gRPC, S3 storage and
  Stripe payments (see the [Ecosystem](ecosystem.md)).
- **The road to 1.0** is written down, with the status of each step, in
  "Toward 1.0", the last section of the [design document](design.md).

## Who is behind it

Livery is developed and maintained by
[Enki Multimedia](https://enki-multimedia.eu). Companies that rely on
it can reach out for support or sponsorship through the contact on the
[project page](https://github.com/benoitc/livery#sponsors).

## Learn more

- [Overview](overview.md): the same story for developers, with the
  design principles.
- [Quickstart](quickstart.md): a working service in five minutes.
- [Design document](design.md): how it is built and why.
