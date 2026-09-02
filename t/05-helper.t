use v5.12;
use strict;
use warnings;
use Test::More;

my $script = q{
    source available/_bash-helper-functions.sh
    export ASGS_MON_COUNT=2
    export ASGS_MON_DELAY=10
    export ASGS_MON_PROFILE=test
    export ASGS_MON_OLDOUT=remember-me
    export ASGS_MON_VERBOSE=0
    mon_init
    mon_every 5
    echo should-not-run
};

my $out = qx{bash -c '$script'};
is($? >> 8, 0, q{mon_every skipped check with OK});
is($out, q{remember-me}, q{mon_every preserves OLDOUT});

done_testing;
