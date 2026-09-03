use v5.12;
use strict;
use warnings;
use Test::More;
use File::Find qw/find/;

my @bash;
find(
    sub {
        return if not -f $_;
        my $path = $File::Find::name;
        open my $fh, q{<}, $path or return;
        my $first = <$fh> // q{};
        close $fh;
        push @bash, $path if $first =~ /bash/;
    },
    qw/available examples adapters/
);

for my $file (sort @bash) {
    my $rc = system(q{bash}, q{-n}, $file);
    is($rc, 0, "bash syntax: $file");
}

for my $file (qw/available\/001-instance-status-check available\/002-hook-status-check available\/atcf-sanity lib\/ASGS\/Mon\/ATCF.pm examples\/check-template.pl/) {
    my $rc = system($^X, q{-c}, $file);
    is($rc, 0, "perl syntax: $file");
}

done_testing;
