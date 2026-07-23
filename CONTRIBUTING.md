# Contributing to cimd

This document describes the process of contributing to cimd. It is intended
for anyone considering opening an **issue** or **pull request**.

`cimd` is alpha software. Using `cimd` today means participating in its
development.

`cimd` is not yet complete. The main functionality is present but it is only
tested against the Dutch transmission grid model. We are fully aware that there
will be edge cases of other TSO members that are not considered yet. We are
working hard to make cimd ENTSOE-complete.

So, using cimd today does imply participating in the development process to
some degree, which usually means inquiring about the development status of a
feature you need, or reporting a bug by opening an issue on CodeBerg. You are
most welcome to get in touch so we can improve cimd for your usecase.

## The Critical Rule

**The most important rule: you must understand your code.** If you can't
explain what your changes do and how they interact with the greater system
without the aid of AI tools, do not contribute to this project.

Using AI to write code is fine. You can gain understanding by interrogating an
agent with access to the codebase until you grasp all edge cases and effects
of your changes. What's not fine is submitting agent-generated slop without
that understanding.

## Quick Guide

### I'd like to contribute

All issues are actionable. Pick one and start working on it. Thank you. If you
need help or guidance, comment on the issue. Issues that are extra friendly to
new contributors are labeled with ['good first issue'].

### I have a bug! / Something isn't working

First, search the issue tracker for similar issues. Tip: also
search for [closed issues] -- your issue might have already
been fixed!

> [!NOTE]
>
> If there is an _open_ issue that matches your problem,
> **please do not comment on it unless you have valuable insight to add**.

If your issue hasn't been reported already, open a ['bug'] issue and make sure
to be as clear as possible, ideally with steps to replicate. They are vital for
maintainers to figure out important details about your setup.

### I have an idea for a feature

Like bug reports, first search through issues and try to find if your feature
has already been requested. Otherwise, open an ['enhancement'] issue and explain
your desired feature as clear as possible. Also specify why this feature should
make it to cimd.

### I've implemented a feature

1. If there is an issue for the feature, open a pull request straight away.
2. If there is no issue, open an ['enhancement'] and link to your branch.
3. If you want to live dangerously, open a pull request and hope for the best.

### I have a question which is neither a bug report nor a feature request

Open a ['question'] issue.

## Style

We use [Tiger Style](docs/TIGER_STYLE.md) from TigerBeetle. New contributors
are expected to read and internalize it.
