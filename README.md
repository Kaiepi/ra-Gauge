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

```raku
class Gauge is Seq { ... }
```

`Gauge` attempts to time iterations of a block as accurately as is doable from within the realms of Raku. While this does not make for a very sophisticated benchmark on its own by virtue of its limitations, this may provide raw input for such a utility.

Any `Gauge` sequence will evauate side effects during a `skip` rather than a `sink`, allowing for a warmup period.

METHODS
=======

CALL-ME
-------

```raku
method CALL-ME(::?CLASS:_: Block:D $block --> ::?CLASS:D)
```

Produces a lazy sequence of native `int` durations of a call to the given block. As such, the size of a duration is constrained by `$?BITS` and is prone to overflows. Measurements of each duration are **not** monotonic, thus leap seconds and hardware errors will skew results.

poll
----

```raku
method poll(::?CLASS:D: Real:D $seconds --> ::?CLASS:D)
```

Returns a new `Gauge` sequence that produces an `Int:D` count of iterations of the former over a duration of `$seconds`.

throttle
--------

```raku
method throttle(::?CLASS:D: Real:D $seconds --> ::?CLASS:D)
```

Returns a new `Gauge` sequence that will sleep `$seconds` between iterations of the former.

AUTHOR
======

Ben Davies (Kaiepi)

COPYRIGHT AND LICENSE
=====================

Copyright 2021 Ben Davies

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

