![Build Status](https://github.com/Kaiepi/ra-Gauge/actions/workflows/test.yml/badge.svg)

NAME
====

Gauge - Iterative polling

SYNOPSIS
========

```raku
use v6.d;
use Gauge;
# How fast can 1..100 be sunk? Take an estimate of how many iterations can be
# completed in 1 second every 20 seconds:
.say for Gauge(-> --> Nil { sink 1..100 }).poll(1).throttle(19);
```

DESCRIPTION
===========

`Gauge` attempts to time iterations of a block as accurately as is doable from
within the realms of Raku. While this does not make for a very sophisticated
benchmark on its own by virtue of its limitations, this may provide raw input
for such a utility. A proper benchmark based on `Gauge` would perform statistics
to ensure leap seconds and hardware errors have a harder time influencing
results (as this module cannot measure time monotonically without the overhead
of doing so carrying a greater influence over its results), while ensuring a
duration is small enough not to overflow a native `int` (of size `$?BITS`).

AUTHOR
======

Ben Davies (Kaiepi)

COPYRIGHT AND LICENSE
=====================

Copyright 2021 Ben Davies

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.
