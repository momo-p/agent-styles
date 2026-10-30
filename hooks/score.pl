#!/usr/bin/env perl
# Scores text for AI-writing tells with the same checks and budgets as the prose lint.
#
#   score.pl <file>...   score each file: Markdown and text whole, source files by their comments
#   score.pl             score stdin as Markdown
#
# Exits 1 when any input is over a budget or carries a stock AI word, 2 when a file can't be read.
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::RealBin/lib";
use Lint qw(prose_hits structure_report lint_view);

binmode STDOUT, ':utf8';

my $status = 0;

sub score {
    my ($label, $text, %opt) = @_;
    my @words = prose_hits($text, 0);
    my ($lines, @rows) = structure_report($text, %opt);
    my $over = grep { $_->{over} } @rows;
    my $fails = $over + (@words ? 1 : 0);
    $status ||= 1 if $fails;

    printf "%s: %s, %d prose lines\n", $label, $fails ? "fail ($fails of " . (@rows + 1) . ' checks)' : 'pass', $lines;
    printf "  %-24s %s\n", 'stock AI words', @words ? join(', ', @words) . '  over' : 'none';
    printf "  %-24s %d of %d allowed%s\n", $_->{name}, $_->{count}, $_->{allowed}, $_->{over} ? '  over' : '' for @rows;
    print "  (under 8 prose lines: structure budgets not enforced)\n" if $lines < 8;
}

unless (@ARGV) {
    local $/;
    binmode STDIN, ':utf8';
    score('stdin', <STDIN> // '');
    exit $status;
}

for my $path (@ARGV) {
    my $text = do { local $/; open my $fh, '<:utf8', $path or do { warn "score: $path: $!\n"; $status = 2; next }; <$fh> // '' };
    my ($view, %opt) = lint_view($path, $text);
    if (defined $view) { score($path, $view, %opt) }
    else               { print "$path: skipped (exempt or no prose to lint)\n" }
}
exit $status;
