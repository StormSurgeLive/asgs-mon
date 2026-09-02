use v5.12;
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Spec;

my $tmp = tempdir(CLEANUP => 1);
my $root = File::Spec->catdir($tmp, q{root});
make_path("$root/available", "$root/active", "$root/adapters/available", "$root/adapters/active");

for my $name (qw/003-example 010-other/) {
    my $path = "$root/available/$name";
    open my $fh, q{>}, $path or die $!;
    print {$fh} "#!/usr/bin/env bash\nexit 0\n";
    close $fh;
    chmod 0755, $path;
}

local $ENV{ASGS_MON_ROOT} = $root;

my $list = qx{$^X bin/asgs-mon --list 2>&1};
is($? >> 8, 0, q{--list exits zero});
like($list, qr/disabled\s+003-example/, q{available check shown disabled});

my $enable = qx{$^X bin/asgs-mon --enable 003 2>&1};
is($? >> 8, 0, q{--enable exits zero});
ok(-l "$root/active/003-example", q{enable creates symlink});

$list = qx{$^X bin/asgs-mon --list 2>&1};
like($list, qr/enabled\s+003-example/, q{enabled check shown});

my $disable = qx{$^X bin/asgs-mon --disable 003 2>&1};
is($? >> 8, 0, q{--disable exits zero});
ok(!-e "$root/active/003-example" && !-l "$root/active/003-example", q{disable removes symlink});

symlink q{../available/does-not-exist}, "$root/active/099-broken" or die $!;
$list = qx{$^X bin/asgs-mon --list 2>&1};
like($list, qr/broken\s+099-broken/, q{broken custom active symlink is visible});
my $broken_disable = qx{$^X bin/asgs-mon --disable 099 2>&1};
is($? >> 8, 0, q{broken active symlink can be disabled from CLI});
ok(!-l "$root/active/099-broken", q{broken symlink removed});

done_testing;
