use v6.d;
die 'A VM version of v2022.04 or later is required for uint bug fixes' if $*VM.version < v2022.04;
unit class Gauge:ver<1.0.1>:auth<zef:Kaiepi>:api<1> is Seq;

#|[ A temporal, lazy, non-deterministic iterator that will evaluate side
    effects moreso when skipping iterations than when sinking them away. ]
role Iterator does Iterator {
    method is-lazy(::?CLASS:_: --> True) { }

    method is-deterministic(::?CLASS:_: --> False) { }

    method time-one(::?CLASS:_:) { ... }

    method skip-one(::?CLASS:_:) { ... }

    method sink-all(::?CLASS:_:) { ... }

}
#=[ This is expected to be able to coerce via list. The singleton list
    provided by the default Any parent is OK unless this is mutable. ]

method new(::?CLASS:_: Iterator:D $it --> ::?CLASS:D) {
    callwith $it
}

#|[ Produces a nanosecond duration of a call to a block. ]
class It does Iterator {
    has $!block;

    submethod BUILD(::?CLASS:D: Block:D :$block! --> Nil) {
        use nqp;
        $!block := nqp::getattr(nqp::decont($block), Code, '$!do');
    }

    method CALL-ME(::?CLASS:_: $block --> ::?CLASS:D) {
        self.bless: :$block
    }

    method time-one(::?CLASS:D: --> uint64) {
        # XXX: A monotonic solution via Inline::Perl5 takes too long to take
        # the time, slashing the number of iterations that can be counted. A
        # NativeCall solution is apt to have the similar problems. Using &now
        # or even comparing the nqp::time to determine if a jump has occurred
        # will influence results too. Basically, if you run this during a leap
        # second or encounter any hardware errors, results will be skewed.
        use nqp;
        nqp::stmts(
          (my uint64 $begin = nqp::time()),
          nqp::call($!block),
          nqp::sub_i(nqp::time(), $begin))
    }

    method pull-one(::?CLASS:D: --> uint64) {
        self.time-one
    }

    method skip-one(::?CLASS:D: --> True) {
        self.pull-one # boop any optimizers
    }

    method sink-all(::?CLASS:D: --> IterationEnd) { }
}
#=[ This is based off the real clock time, and isn't monotonic as a
    consequence. ]

#|[ Produces a lazy sequence of uint64 durations of calls to a block via
    Gauge::It. ]
method CALL-ME(::?CLASS:_: Block:D $block --> ::?CLASS:D) {
    self.new: It($block)
}

#|[ Counts iterations over a nanosecond duration. ]
class Poller does Iterator {
    has $!ns;
    has $!it;

    submethod BUILD(::?CLASS:D: Real:D :$seconds!, Iterator:D :$it! --> Nil) {
        $!ns  = $seconds * 1_000_000_000 +^ 0;
        $!it := $it<>;
    }

    method CALL-ME(::?CLASS:_: $seconds, $it --> ::?CLASS:D) {
        self.bless: :$seconds, :$it
    }

    method time-one(::?CLASS:D:) {
        use nqp;
        nqp::stmts(
          (my $ns is default(0)),
          nqp::repeat_while(($ns < $!ns), ($ns += $!it.time-one)),
          $ns)
    }

    method pull-one(::?CLASS:D:) {
        use nqp;
        nqp::stmts(
          (my $ns is default(0)),
          (my $n is default(0)),
          nqp::while((($ns += $!it.time-one) < $!ns), ($n++)),
          $n)
    }

    method skip-one(::?CLASS:D: --> True) {
        use nqp;
        nqp::stmts(
          (my $ns is default(0)),
          nqp::repeat_while(($ns < $!ns), ($ns += $!it.time-one)))
    }

    method sink-all(::?CLASS:D:) {
        $!it.sink-all
    }
}

#|[ Counts iterations of the gauged block over a number of seconds via
    Gauge::Poller. ]
method poll(::?CLASS:D: Real:D $seconds --> ::?CLASS:D) {
    self.new: Poller($seconds, self.iterator)
}

#|[ Sleeps a number of seconds between iterations. ]
class Throttler does Iterator {
    has num $!seconds;
    has $!it;
    has $!sleeps is default(False);

    submethod BUILD(::?CLASS:D: Num(Real:D) :$!seconds!, Iterator:D :$it! --> Nil) {
        $!it := $it<>;
    }

    method CALL-ME(::?CLASS:_: $seconds, $it --> ::?CLASS:D) {
        self.bless: :$seconds, :$it
    }

    method time-one(::?CLASS:D:) {
        use nqp;
        (nqp::cas($!sleeps, False, True) && clock $!seconds) + $!it.time-one
    }

    method pull-one(::?CLASS:D:) {
        use nqp;
        (nqp::cas($!sleeps, False, True) && block $!seconds) || $!it.pull-one
    }

    method skip-one(::?CLASS:D:) {
        use nqp;
        (nqp::cas($!sleeps, False, True) && block $!seconds) || $!it.skip-one
    }

    method sink-all(::?CLASS:D:) {
        $!it.sink-all # just do it
    }

    sub block(num $seconds --> False) is pure {
        use nqp;
        nqp::sleep($seconds)
    }

    sub clock(num $seconds --> uint64) is pure {
        use nqp;
        nqp::stmts(
          (my uint64 $ns = nqp::time()),
          nqp::sleep($seconds),
          nqp::sub_i(nqp::time(), $ns))
    }
}

#|[ Sleeps a number of seconds between iterations of the gauged block via
    Gauge::Throttler. ]
method throttle(::?CLASS:D: Real:D $seconds --> ::?CLASS:D) {
    self.new: Throttler($seconds, self.iterator)
}

#|[ A thread that can map a Gauge::Iterator by making a pledge to reevaluate a
    command after each request to make one, ahead of any presumed repetition. ]
class Covenant is Thread does Iterator {
    my $band is default(0);

    has $!it;
    has $!wanted;
    has $!marked;
    has $!taking is default(False);
    has $!command;
    has $!message;

    submethod BUILD(::?CLASS:D: Iterator:D :$it! --> Nil) {
        $!it     := $it<>;
        $!wanted := Semaphore.new: 0;
        $!marked := Semaphore.new: 1;
    }

    method new(::?CLASS:_: Iterator:D :$it! --> ::?CLASS:D) {
        callwith :$it, :code(&answer), :name('gauge ' ~ cas $band, *.succ), :app_lifetime
    }

    proto method CALL-ME(::?CLASS:_: $ --> ::?CLASS:D) {*}
    multi method CALL-ME(::?CLASS:_: Iterator:D $it) {
        self.new: :$it
    }
    multi method CALL-ME(::?CLASS:_: Gauge:D $gauged) {
        self.new: :it($gauged.iterator)
    }
    multi method CALL-ME(::?CLASS:_: ::?CLASS:D $pledge) {
        $pledge
    }

    method run(::?CLASS:D: --> ::?CLASS:D) {
        use nqp;
        nqp::cas($!taking, False, True) ?? self !! (callsame)
    }

    method finish(::?CLASS:D: --> ::?CLASS:D) {
        use nqp;
        nqp::cas($!taking, True, False) ?? (callsame) !! self
    }

    method time-one(::?CLASS:D:) {
        self.request: my constant &time-one = *.time-one
    }

    method pull-one(::?CLASS:D:) {
        self.request: my constant &pull-one = *.pull-one
    }

    method skip-one(::?CLASS:D:) {
        self.request: my constant &skip-one = *.skip-one
    }

    method sink-all(::?CLASS:D:) {
        my $sunken := self.request: my constant &sink-all = *.sink-all;
        self.finish;
        $sunken
    }

    method request(::?CLASS:D: $command) {
        # We only block when we know we're not repeating the previous command.
        use nqp;
        nqp::eqaddr(nqp::atomicload($!command), nqp::decont($command))
          ?? (follow self)
          !! (follow pledge self, $command)
    }

    my method pledge(::?CLASS:D: $command) {
        # Prescribe a command to evaluate repetitively from a separate thread.
        use nqp;
        nqp::stmts(
          nqp::semacquire($!marked),
          nqp::atomicstore($!command, $command),
          nqp::semrelease($!wanted),
          self.run)
    }

    my method answer(::?CLASS:D $ = $*THREAD: --> Nil) {
        # Respond to commands from the root thread with an evaluation of ours.
        use nqp;
        nqp::while(
          nqp::atomicload($!taking),
          nqp::stmts(
            nqp::semacquire($!wanted),
            nqp::atomicstore($!message, nqp::atomicload($!command)($!it)),
            nqp::semrelease($!marked)));
    }

    my method follow(::?CLASS:D:) {
        # Take the response to a request, following through on its redo pledge.
        use nqp;
        nqp::stmts(
          nqp::semacquire($!marked),
          (my $message := nqp::atomicload($!message)),
          nqp::semrelease($!wanted),
          $message)
    }
}

#|[ Concatenates a flattened list of iterators, each bound via Gauge::Covenant. ]
class Contract does Iterator {
    has @!frames;
    has uint $!length;
    has uint $!reader;
    has uint $!writer;

    submethod BUILD(::?CLASS:D: :@frames! --> Nil) {
        @!frames := @frames.map({ Covenant($^it) }).eager;
        $!length  = @!frames.elems;
    }

    method CALL-ME(::?CLASS:_: *@frames --> ::?CLASS:D) {
        self.bless: :@frames
    }

    method step-one(::?CLASS:D: --> uint) {
        use nqp;
        ($!reader ||= ($!writer >= $!length ?? $!length !! ++$!writer)) -= 1
    }

    method time-one(::?CLASS:D:) {
        @!frames.AT-POS(self.step-one).time-one
    }

    method pull-one(::?CLASS:D:) {
        @!frames.AT-POS(self.step-one).pull-one
    }

    method skip-one(::?CLASS:D:) {
        @!frames.AT-POS(self.step-one).skip-one
    }

    method sink-all(::?CLASS:D: --> IterationEnd) {
        @!frames.AT-POS(self.step-one).sink-all xx $!length
    }

    multi method list(::?CLASS:D:) {
        @!frames
    }
}
#|[ This will start threads in sequence, but will exhaust any initialized
    threads in a cycle of iterations in reverse before running a new one. ]

#|[ Threads iterations while making an eager contract to predict iterations via
    Gauge::Contract and Gauge::Covenant. ]
method pledge(::?CLASS:D: UInt:D $length --> ::?CLASS:D) {
    my $it := self.iterator;
    my $cs := head $length, flat @$it xx *;
    self.new: $cs.elems == 1 ?? Covenant($cs.head) !! $cs ??  Contract(@$cs) !! $it
}
