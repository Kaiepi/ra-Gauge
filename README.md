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

Any `Gauge` sequence will be lazy and non-deterministic. These evaluate side effects during a `skip` rather than a `sink`, allowing for a warmup period.

ATTRIBUTES
==========

$!raw
-----

    has Bool:D $.raw is default(so $*VM.name eq <moar jvm>.none);

`$!raw` toggles garbage collection before intensive iterations in general, i.e. those of `poll` currently. By default, this will be `False` on MoarVM and the JVM. If set to `True`, iterations are very likely to be skewed by any interruption due to GC, but with enough time and tinkering, the greatest of ideal results should be achievable.

METHODS
=======

CALL-ME
-------

```raku
method CALL-ME(::?CLASS:_: Block:D $block, *%attrinit --> ::?CLASS:D)
```

Produces a new `Gauge` sequence of native `int` durations of a call to the given block. As such, the size of a duration is constrained by `$?BITS` and is prone to underflows. Measurements of each duration are **not** monotonic, thus leap seconds and hardware errors will skew results.

If `%attrinit` is provided, a clone will be produced with it to allow for attributes to be set.

poll
----

```raku
method poll(::?CLASS:D: Real:D $seconds --> ::?CLASS:D)
```

Returns a new `Gauge` sequence that produces an `Int:D` count of iterations of the former totalling a duration of `$seconds`. This will take longer than the given argument to complete due to the overhead of iteration.

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

