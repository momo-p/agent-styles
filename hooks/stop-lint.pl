#!/usr/bin/env perl
# Stop: lints the final reply and every file the working tree changed, with the prose lint's
# checks. Hits exit 2, which keeps the turn going once; stop_hook_active lets the next stop through.
use strict;
use warnings;
use utf8;
use Encode ();
use FindBin;
use lib "$FindBin::RealBin/lib";
use Lint qw(read_input prose_hits structure_hits lint_view git_lines block);

my $MAX_FILES = 50;
my $MAX_BYTES = 1_000_000;

my ($raw, $decode) = read_input();
my $in = $decode->();
exit 0 if $in->{stop_hook_active};
my $cwd = $in->{cwd} // $ENV{CLAUDE_PROJECT_DIR} // '.';

my @report;

my $reply = $in->{last_assistant_message} // '';
if ($reply =~ /\S/) {
    my @hits = (prose_hits($reply, 0), structure_hits($reply, undef));
    push @report, 'your last reply: ' . join(', ', @hits) if @hits;
}

# Added lines per changed file, against HEAD; an untracked file counts as added whole.
my $root = join '', git_lines('-C', $cwd, 'rev-parse', '--show-toplevel');
chomp $root;
my %added;
if (length $root) {
    my $file;
    for (git_lines('-C', $root, 'diff', 'HEAD', '--unified=0', '--no-color', '--no-ext-diff', '--diff-filter=AM')) {
        if    (m{^\+\+\+ b/(.*)$})   { $file = $1 }
        elsif (/^\+\+\+ /)           { undef $file }
        elsif ($file && s/^\+//)     { $added{$file} .= Encode::decode_utf8($_) }
    }
    for (git_lines('-C', $root, 'ls-files', '--others', '--exclude-standard')) {
        chomp;
        $added{$_} = undef;
    }
}

my $checked = 0;
for my $rel (sort keys %added) {
    last if ++$checked > $MAX_FILES;
    my $path = "$root/$rel";
    next unless -f $path && -s _ <= $MAX_BYTES;
    my $text = do { open my $fh, '<:utf8', $path or next; local $/; <$fh> // '' };
    my ($whole, %opt) = lint_view($path, $text) or next;
    my ($new) = defined $added{$rel} ? lint_view($path, $added{$rel}) : ($whole);
    next unless defined $new && $new =~ /\S/;
    my @hits = (prose_hits($new, 0), structure_hits($whole, $new, %opt));
    push @report, "$rel: " . join(', ', @hits) if @hits;
}

block('stop-lint', 'AI-writing tells before finishing:', @report,
      'Fix the files per the Writing rules in AGENTS.md. For the reply, resend only the corrected sentences.') if @report;
exit 0;
