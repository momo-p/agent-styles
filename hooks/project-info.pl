#!/usr/bin/env perl
# SessionStart: prints a short fact sheet of the project so the agent starts from real names,
# not guesses. Only filenames and short lists; prints nothing outside a recognizable project.
use strict;
use warnings;

my $root = $ENV{CLAUDE_PROJECT_DIR} // do { require Cwd; Cwd::getcwd() };
chdir $root or exit 0;

sub slurp { open my $fh, '<', shift or return ''; local $/; <$fh> // '' }
sub short { my ($max, @xs) = @_; @xs > $max ? (join(', ', @xs[0 .. $max - 1]) . ', …') : join(', ', @xs) }

my @lines;

my %manifest = (
    'go.mod' => 'Go', 'Cargo.toml' => 'Rust', 'package.json' => 'JS/TS', 'pyproject.toml' => 'Python',
    'requirements.txt' => 'Python', 'flake.nix' => 'Nix', 'build.zig' => 'Zig', 'CMakeLists.txt' => 'C/C++',
    'pom.xml' => 'Java', 'build.gradle' => 'JVM', 'build.gradle.kts' => 'JVM', 'Gemfile' => 'Ruby',
    'mix.exs' => 'Elixir', 'composer.json' => 'PHP', 'deno.json' => 'Deno', 'devenv.nix' => 'devenv',
    'rust-toolchain.toml' => 'Rust toolchain',
);
my @found = grep { -e } sort keys %manifest;

# Monorepos keep manifests in subdirectories; report them grouped, up to two levels deep.
my @nested;
for my $m (sort keys %manifest) {
    my @paths = grep { !m{(?:^|/)(?:node_modules|vendor|target|\.[^/]+)/} } (glob("*/$m"), glob("*/*/$m"));
    next unless @paths;
    push @nested, @paths > 3 ? "$m ×" . @paths . " (e.g. $paths[0])" : join(', ', @paths);
}
exit 0 unless @found || @nested || -d '.git';

push @lines, 'Manifests: ' . join(', ', map { "$_ ($manifest{$_})" } @found) if @found;
push @lines, 'Nested manifests: ' . short(6, @nested) if @nested;

if (-e 'go.mod' and slurp('go.mod') =~ /^go\s+(\S+)/m) { push @lines, "Go version: $1" }
if (-e 'Cargo.toml' and slurp('Cargo.toml') =~ /^edition\s*=\s*"(\d+)"/m) { push @lines, "Rust edition: $1" }

if (-e 'package.json') {
    my $pkg = slurp('package.json');
    if ($pkg =~ /"scripts"\s*:\s*\{(.*?)\}/s) {
        my @s = $1 =~ /"([^"]+)"\s*:/g;
        push @lines, 'npm scripts: ' . short(15, @s) if @s;
    }
    my ($pm) = grep { -e $_->[0] } ['pnpm-lock.yaml', 'pnpm'], ['yarn.lock', 'yarn'], ['bun.lockb', 'bun'],
        ['bun.lock', 'bun'], ['package-lock.json', 'npm'];
    push @lines, "Package manager: $pm->[1]" if $pm;
}

for my $mk (grep { -e } qw(Makefile makefile GNUmakefile)) {
    my @t = grep { !/^\./ } slurp($mk) =~ /^([A-Za-z0-9][\w.-]*)\s*:(?!=)/mg;
    push @lines, "make targets: " . short(15, @t) if @t;
}
for my $jf (grep { -e } qw(justfile Justfile .justfile)) {
    my @r = slurp($jf) =~ /^@?([A-Za-z][\w-]*)[^\n:=]*:(?!=)/mg;
    push @lines, "just recipes: " . short(15, @r) if @r;
}

my @ci = (glob('.github/workflows/*.y*ml'), grep { -e } qw(.gitlab-ci.yml .circleci/config.yml Jenkinsfile));
push @lines, 'CI: ' . short(6, @ci) if @ci;

my @fmt = grep { -e } qw(treefmt.toml .treefmt.toml .prettierrc .prettierrc.json .editorconfig .golangci.yml
                         .golangci.yaml ruff.toml .clang-format stylua.toml .eslintrc.json eslint.config.js
                         biome.json rustfmt.toml);
push @lines, 'Lint/format config: ' . join(', ', @fmt) if @fmt;

# Claude Code auto-loads CLAUDE.md files; the others it does not, so point at them.
my @docs = grep { -e } qw(AGENTS.md CONTRIBUTING.md GEMINI.md .cursorrules docs/ARCHITECTURE.md ARCHITECTURE.md);
push @lines, 'Read before editing (not auto-loaded): ' . join(', ', @docs) if @docs;

exit 0 unless @lines;
print "Project facts for $root (from files on disk; verify anything not listed):\n";
print "- $_\n" for @lines;
