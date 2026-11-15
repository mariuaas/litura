#!/usr/bin/perl
# Perl: heredocs, regexes, quote-like operators, references. Ünïcode ✓
use strict;
use warnings;
use utf8;

my %config = (name => 'démo', sizes => [1, 2, 3], ratio => 3 / 4);
my @words = qw(alpha beta gamma);
my $count = scalar @words;

sub greet {
    my ($who, %opts) = @_;
    my $prefix = $opts{prefix} // 'hello';
    return "$prefix, $who";
}

my $text = <<"END";
Interpolated heredoc for $config{name}
with @{[ greet('you') ]}
END

my $raw = <<'RAW';
No $interpolation here
RAW

print <<~INDENTED;
    An indented heredoc
    ends at the marker
    INDENTED

for my $word (@words) {
    if ($word =~ m/^a(\w+)/x) {
        print "match: $1\n";
    } elsif ($word =~ s{ta}{TA}gr) {
        next;
    } else {
        (my $copy = $word) =~ tr/a-z/A-Z/;
    }
}

my $ref = { list => [map { $_ * 2 } grep { $_ % 2 } 1 .. 10], code => sub { $_[0] + 1 } };
printf "%d %s %s\n", $ref->{code}->(41), join(',', @{ $ref->{list} }), q{braces {nested}};
open(my $fh, '<', $0) or die "cannot open: $!";
while (my $line = <$fh>) { chomp $line; last if $. > 3 }
close $fh;
