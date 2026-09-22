#!/usr/bin/env perl
# Per-project knowledge cache. Each fact is pinned to the hashes of the files it came from;
# a fact is dropped as soon as any of those files changes or disappears.
#
#   know.pl add "<one-line fact>" <file>...   record a fact backed by these files
#   know.pl list                             print the facts that are still valid
#   know.pl rm <id>...                       delete facts
#   know.pl session                          SessionStart: prune stale facts, print the rest
use strict;
use warnings;
use Digest::SHA ();
use Fcntl qw(:flock SEEK_SET);
use File::Path qw(make_path);
use JSON::PP ();

my $MAX_FACT  = 200;
my $MAX_SHOWN = 25;

my ($cmd, @args) = @ARGV;
$cmd //= 'list';

my $start = $cmd eq 'session' ? ($ENV{CLAUDE_PROJECT_DIR} // '.') : '.';
my $root = do {
    open my $saved, '>&', \*STDERR;
    open STDERR, '>', '/dev/null';
    my ($git, $r);
    $r = open($git, '-|', 'git', '-C', $start, 'rev-parse', '--show-toplevel') ? <$git> // '' : '';
    open STDERR, '>&', $saved;
    chomp $r;
    $r;
};
$root ||= do { require Cwd; Cwd::abs_path($start) };
(my $key = $root) =~ s{[^A-Za-z0-9]+}{-}g;
my $dir   = ($ENV{STYLE_AGENTS_KNOWLEDGE_DIR} // "$ENV{HOME}/.claude/knowledge");
my $store = "$dir/$key.json";

sub hash_of { my $p = "$root/$_[0]"; -f $p ? Digest::SHA->new(1)->addfile($p)->hexdigest : undef }

sub is_valid {
    my ($fact) = @_;
    for (@{ $fact->{sources} }) { my $h = hash_of($_->{path}); return 0 unless defined $h && $h eq $_->{sha1} }
    return 1;
}

# Opens the store under an exclusive lock and returns (handle, facts).
sub open_store {
    make_path($dir);
    open my $fh, '+>>', $store or die "know: cannot open $store: $!\n";
    flock $fh, LOCK_EX;
    seek $fh, 0, SEEK_SET;
    local $/;
    my $raw = <$fh> // '';
    my $facts = length $raw ? eval { JSON::PP->new->utf8->decode($raw) } // [] : [];
    return ($fh, $facts);
}

sub save {
    my ($fh, $facts) = @_;
    truncate $fh, 0;
    print {$fh} JSON::PP->new->utf8->canonical->pretty->encode($facts);
    close $fh;
}

sub line { my $f = shift; "- [$f->{id}] $f->{fact} (" . join(', ', map { $_->{path} } @{ $f->{sources} }) . ')' }

if ($cmd eq 'add') {
    my ($text, @paths) = @args;
    die "usage: know.pl add \"<fact>\" <file>...\n" unless defined $text && @paths;
    utf8::decode($text);
    $text =~ s/\s+/ /g;
    die "know: fact must be at most $MAX_FACT characters\n" if length $text > $MAX_FACT;
    require Cwd;
    my @sources;
    for my $p (@paths) {
        my $abs = Cwd::abs_path($p);
        die "know: $p is not a file; facts must cite files that exist\n" unless $abs && -f $abs;
        die "know: $p is outside the project ($root)\n" unless index($abs, "$root/") == 0;
        my $rel = substr $abs, length("$root/");
        push @sources, { path => $rel, sha1 => hash_of($rel) };
    }
    my ($fh, $facts) = open_store();
    @$facts = grep { $_->{fact} ne $text } @$facts;
    my $id = 1 + (sort { $b <=> $a } 0, map { $_->{id} } @$facts)[0];
    push @$facts, { id => $id, fact => $text, sources => \@sources, recorded => time };
    save($fh, $facts);
    print "know: recorded [$id]\n";
}
elsif ($cmd eq 'rm') {
    my %drop = map { $_ => 1 } @args;
    my ($fh, $facts) = open_store();
    my $before = @$facts;
    @$facts = grep { !$drop{ $_->{id} } } @$facts;
    save($fh, $facts);
    printf "know: removed %d\n", $before - @$facts;
}
elsif ($cmd eq 'list' || $cmd eq 'session') {
    exit 0 if $cmd eq 'session' && !-e $store;
    my ($fh, $facts) = open_store();
    my @valid = grep { is_valid($_) } @$facts;
    my $stale = @$facts - @valid;
    if ($cmd eq 'session') { save($fh, \@valid) } else { close $fh }
    exit 0 unless @valid || $stale;
    binmode STDOUT, ':utf8';
    if (@valid) {
        my @recent = (sort { $b->{recorded} <=> $a->{recorded} } @valid)[0 .. ($#valid < $MAX_SHOWN - 1 ? $#valid : $MAX_SHOWN - 1)];
        print "Cached project knowledge (source files unchanged since recorded; add/rm with ~/.claude/hooks/know.pl):\n";
        print line($_), "\n" for sort { $a->{id} <=> $b->{id} } @recent;
        printf "(%d older facts not shown; run know.pl list)\n", @valid - @recent if @valid > @recent;
    }
    printf "Dropped %d cached fact(s) whose source files changed; re-verify before relying on that area.\n", $stale if $stale;
}
else {
    die "know: unknown command '$cmd' (add, list, rm, session)\n";
}
