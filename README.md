![Build Status](https://github.com/Kaiepi/ra-Gauge/actions/workflows/test.yml/badge.svg)

NAME
====

Gauge - Iterative polling

SYNOPSIS
========

```raku
use v6.d;
use Gauge;
# How fast can (1..10) be generated? Take an estimate of how many iterations
# can be sunk in 1 second every 20 seconds:
.say for Gauge(-> --> Nil { sink 1..10 }).poll(1).throttle(19);
```

DESCRIPTION
===========

```raku
class Gauge is Seq { ... }
```

`Gauge`, in general, wraps a lazy, non-deterministic, time-oriented iterator. At its base, it attempts to measure durations of calls to a block with as little overhead as possible in order to avoid unnecessary influence over results. This does not make for a proper benchmark on its own, but may provide raw input for such a utility.

ATTRIBUTES
==========

$!gc
----

```raku
has Bool:D $.gc is default(so $*VM.name eq <moar jvm>.any);
```

`$!gc` toggles garbage collection before intensive iterations in general, i.e. those of `poll` currently. By default, this will be `True` on MoarVM and the JVM. If set to `False`, iterations are very likely to be skewed by any interruption due to GC (if available).

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

Copyright 2022 Ben Davies

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

