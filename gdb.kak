# script summary:
# a long running shell process starts a gdb session (or connects to an existing one) and handles input/output
# kakoune -> gdb communication is done by writing the gdb commands to a fifo
# gdb -> kakoune communication is done by an awk process that translates gdb events into kakoune commands
# the gdb-handle-* commands act upon gdb notifications to update the kakoune state

declare-option str gdb_breakpoint_active_symbol "●"
declare-option str gdb_breakpoint_inactive_symbol "○"
declare-option str gdb_location_symbol "➡"

set-face global GdbBreakpoint red,default
set-face global GdbLocation blue,default

# a debugging session has been started
declare-option bool gdb_started false
# the debugged program is currently running (stopped or not)
declare-option bool gdb_program_running false
# the debugged program is currently running, but stopped
declare-option bool gdb_program_stopped false
# if not empty, contains the name of client in which the autojump is performed
declare-option str gdb_autojump_client
# if not empty, contains the name of client in which the value is printed
# set by default to the client which started the session
declare-option str gdb_print_client

# contains all known breakpoints in this format:
# id enabled line file id enabled line file  ...
declare-option str-list gdb_breakpoints_info
# if execution is currently stopped, contains the location in this format:
# line file
declare-option str-list gdb_location_info
# note that these variables may reference locations that are not in currently opened buffers

# list of pending commands that will be executed the next time the process is stopped
declare-option -hidden str gdb_pending_commands

# a visual indicator showing the current state of the script
declare-option str gdb_indicator

# the directory containing the input fifo, pty object and backtrace
declare-option -hidden str gdb_dir

# corresponding flags generated from the previous variables
# these are only set on buffer scope
declare-option -hidden line-specs gdb_breakpoints_flags
declare-option -hidden line-specs gdb_location_flag

addhl shared/gdb group -passes move
addhl shared/gdb/ flag-lines GdbLocation gdb_location_flag
addhl shared/gdb/ flag-lines GdbBreakpoint gdb_breakpoints_flags

define-command -params .. -file-completion gdb-session-new %{
    gdb-session-connect-internal
    nop %sh{
        # can't connect until socat has created the pty thing
        while [ ! -e "${kak_opt_gdb_dir}/pty" ]; do
            sleep 0.1
        done
        if [ -n "$TMUX" ]; then
            tmux split-window -h " \
                gdb $@ --init-eval-command=\"new-ui mi3 ${kak_opt_gdb_dir}/pty\""
        elif [ -n "$WINDOWID" ]; then
            setsid -w $kak_opt_termcmd " \
                gdb $@ --init-eval-command=\"new-ui mi3 ${kak_opt_gdb_dir}/pty\"" 2>/dev/null >/dev/null &
        fi
    }
}

define-command rr-session-new %{
    gdb-session-connect-internal
    nop %sh{
        # can't connect until socat has created the pty thing
        while [ ! -e "${kak_opt_gdb_dir}/pty" ]; do
            sleep 0.1
        done
        if [ -n "$TMUX" ]; then
            tmux split-window -h " \
                rr replay -o --init-eval-command=\"new-ui mi3 ${kak_opt_gdb_dir}/pty\""
        elif [ -n "$WINDOWID" ]; then
            setsid -w $kak_opt_termcmd " \
                rr replay -o --init-eval-command=\"new-ui mi3 ${kak_opt_gdb_dir}/pty\"" 2>/dev/null >/dev/null &
        fi
    }
}

define-command gdb-session-connect %{
    gdb-session-connect-internal
    info "Please instruct gdb to ""new-ui mi3 %opt{gdb_dir}/pty"""
}

define-command -hidden gdb-session-connect-internal %§
    gdb-session-stop
    eval %sh§§
        export tmpdir=$(mktemp --tmpdir -d gdb_kak_XXX)
        mkfifo "${tmpdir}/input_pipe"
        {
            # too bad gdb only exposes its new-ui via a pty, instead of simply a socket
            tail -n +1 -f "${tmpdir}/input_pipe" | socat "pty,link=${tmpdir}/pty" STDIO,nonblock=1 | perl -e 'use strict;
use warnings;
my $session = $ENV{"kak_session"};
my $tmpdir = $ENV{"tmpdir"};
sub escape {
    my $command = shift;
    if (not defined($command)) { return '\'''\''; }
    $command =~ s/'\''/'\'''\''/g;
    return "'\''${command}'\''";
}
sub send_to_kak {
    my $err = shift;
    if ($err) { return $err; }
    my $command = join('\'' '\'', @_);
    my $pid = open(CHILD_STDIN, "|-");
    defined($pid) || die "can'\''t fork: $!";
    $SIG{PIPE} = sub { die "child pipe broke" };
    if ($pid > 0) { # parent
        print CHILD_STDIN $command;
        close(CHILD_STDIN) || return 1;
    } else { # child
        exec("kak", "-p", $session) || die "can'\''t exec program: $!";
    }
    return 0;
}
sub tokenize_val {
    my $ref = shift;
    my $closer = shift;
    my $nested_brackets = 0;
    my $nested_braces = 0;
    my $res = "";
    while (1) {
        if ($$ref !~ m/\G([^",\{\}\[\]]*)([",\{\}\[\]])/gc) {
            return 1;
        }
        $res .= $1;
        if (($2 eq '\'','\'' or $2 eq $closer) and ($nested_braces == 0 and $nested_brackets == 0)) {
            return (0, $res, $2);
        }
        $res .= $2;
        if ($2 eq '\''"'\'') {
            while (1) {
                if ($$ref !~ m/\G([^\\"]*([\\"]))/gc) { return 1; }
                $res .= $1;
                if ($2 eq '\''"'\'') {
                    last;
                }
                if ($$ref !~ m/\G(.)/gc) { return 1; }
                $res .= $1;
            }
        } elsif ($2 eq '\''{'\'') {
            $nested_braces += 1;
        } elsif ($2 eq '\''}'\'') {
            if ($nested_braces == 0) { return 1; }
            $nested_braces -= 1;
        } elsif ($2 eq '\''['\'') {
            $nested_brackets += 1;
        } elsif ($2 eq '\'']'\'') {
            if ($nested_brackets == 0) { return 1; }
            $nested_brackets -= 1;
        }
    }
}
sub parse_string {
    my $prev_err = shift;
    if ($prev_err) { return $prev_err; }
    my $input = shift;
    if (not defined($input)) { return 1; }
    if ($input !~ m/\G"/gc) {
        return 1;
    }
    my $res;
    while (1) {
        if ($input !~ m/\G([^\\"]*)([\\"])/gc) {
            return 1;
        }
        $res .= $1;
        if ($2 eq '\''\\'\'') {
            $input =~ m/\G(.)/gc;
            if ($1 eq "n") {
                $res .= "\n";
            } else {
                $res .= $1;
            }
        } elsif ($2 eq '\''"'\''){
            return (0, $res);
        }
    }
}
sub parse_array {
    my $prev_err = shift;
    if ($prev_err) { return $prev_err; }
    my $input = shift;
    if (not defined($input)) { return 1; }
    if ($input !~ m/\G\[/gc) {
        return 1;
    }
    my @res;
    if ($input =~ m/\G]/gc) {
        return (0, @res);
    }
    while (1) {
        my ($err, $val, $separator) = tokenize_val(\$input, '\'']'\'');
        if ($err) { return 1; }
        push(@res, $val);
        if ($separator eq '\'']'\'') {
            return (0, @res);
        }
    }
    return 1;
}
sub parse_map {
    my $prev_err = shift;
    if ($prev_err) { return $prev_err; }
    my $input = shift;
    if (not defined($input)) { return 1; }
    if ($input !~ m/\G\{/gc) {
        return 1;
    }
    my %res;
    if ($input =~ m/\G}/gc) {
        return (0, %res);
    }
    while (1) {
        if ($input !~ m/\G([A-Za-z_-]+)=/gc) {
            return 1;
        }
        my $key = $1;
        my ($err, $val, $separator) = tokenize_val(\$input, '\''}'\'');
        if ($err) { return 1; }
        $res{$key} = $val;
        if ($separator eq '\''}'\'') {
            return (0, %res);
        }
    }
}
sub fixup_breakpoint_table {
    my $err = shift;
    if ($err) { return $err; }
    my @table = @_;
    my @fixed;
    my $index = 0;
    while ($index < scalar(@table)) {
        my $val = $table[$index];
        if ($val !~ m/^bkpt=(.*)$/) { return 1; }
        my $res = '\''['\'' . $1;
        $index += 1;
        while ($index < scalar(@table)) {
            my $sub = $table[$index];
            if ($sub =~ m/^bkpt=/) { last; }
            $res .= '\'','\'' . $sub;
            $index += 1;
        }
        $res .= '\'']'\'';
        push(@fixed, $res);
    }
    return (0, @fixed);
}
sub breakpoint_to_command {
    my $err = shift;
    if ($err) { return $err; }
    my $cmd = shift;
    my $array = shift;
    my (@bkpt_array, %main_bkpt, $id, $enabled, $line, $file, $addr);
    ($err, @bkpt_array) = parse_array($err, $array);
    ($err, %main_bkpt) = parse_map($err, $bkpt_array[0]);
    ($err, $id) = parse_string($err, $main_bkpt{"number"});
    ($err, $enabled) = parse_string($err, $main_bkpt{"enabled"});
    my $is_multiple = 0;
    if (exists($main_bkpt{"addr"})) {
        ($err, $addr) = parse_string($err, $main_bkpt{"addr"});
        if ($addr eq "<PENDING>") {
            return (0, ());
        } elsif ($addr eq "<MULTIPLE>") {
             $is_multiple = 1;
             my $i = 1;
             while ($i < scalar(@bkpt_array)) {
                my %sub_bkpt;
                ($err, %sub_bkpt) = parse_map($err, $bkpt_array[$i]);
                if (exists($sub_bkpt{"line"}) and exists($sub_bkpt{"fullname"})) {
                    ($err, $line) = parse_string($err, $sub_bkpt{"line"});
                    ($err, $file) = parse_string($err, $sub_bkpt{"fullname"});
                    if ($err) { return $err; }
                    return (0, ($cmd, $id, $enabled, $line, escape($file)));
                }
                $i += 1;
             }
        }
    }
    if (not $is_multiple) {
        ($err, $line) = parse_string($err, $main_bkpt{"line"});
        ($err, $file) = parse_string($err, $main_bkpt{"fullname"});
        if ($err) { return $err; }
        return (0, ($cmd, $id, $enabled, $line, escape($file)));
    }
    return 1;
}
sub get_line_file {
    my $number = shift;
    my $file = shift;
    open(my $fh, '\''<'\'', $file) or return 1;
    while (my $line = <$fh>) {
        if ($. == $number) {
            close($fh);
            $line =~ s/\n$//;
            return (0, $line);
        }
    }
    close($fh);
    return 1;
}
my $connected = 0;
my $printing = 0;
my $print_value = "";
while (my $input = <STDIN>) {
    $input =~ s/\s+\z//;
    my $err = 0;
    if (!$connected) {
        $connected = 1;
        open(my $fh, '\''>'\'', "${tmpdir}/input_pipe") or die;
        print $fh "-gdb-set mi-async on\n";
        print $fh "-break-list\n";
        print $fh "-stack-info-frame\n";
        close($fh);
    }
    if ($input =~ /^\*running/) {
        $err = send_to_kak($err, '\''gdb-handle-running'\'');
    } elsif ($input =~ /^\*stopped,(.*)$/) {
        my (%map, $reason, %frame, $line, $file, $skip);
        ($err, %map) = parse_map($err, '\''{'\'' . $1 . '\''}'\'');
        $skip = 0;
        if (exists($map{"reason"})) {
            ($err, $reason) = parse_string($err, $map{"reason"});
            if ($reason eq "exited" or $reason eq "exited-normally" or $reason eq "exited-signalled") {
                $skip = 1;
            }
        }
        if (not $skip) {
            ($err, %frame) = parse_map($err, $map{"frame"});
            if (exists($frame{"line"}) and exists($frame{"fullname"})) {
                ($err, $line) = parse_string($err, $frame{"line"});
                ($err, $file) = parse_string($err, $frame{"fullname"});
                $err = send_to_kak($err, '\''gdb-handle-stopped'\'', $line, escape($file));
            } else {
                $err = send_to_kak($err, '\''gdb-handle-stopped-unknown'\'');
            }
        }
    } elsif ($input =~ /^=thread-group-exited/) {
        $err = send_to_kak($err, '\''gdb-handle-exited'\'');
    } elsif ($input =~ /\^done,frame=(.*)$/) {
        my (%map, $line, $file);
        ($err, %map) = parse_map($err, $1);
        ($err, $line) = parse_string($err, $map{"line"});
        ($err, $file) = parse_string($err, $map{"fullname"});
        $err = send_to_kak($err, '\''gdb-clear-location'\'', '\'';'\'', '\''gdb-handle-stopped'\'', $line, escape($file));
    } elsif ($input =~ /\^done,stack=(.*)$/) {
        my @array;
        ($err, @array) = parse_array($err, $1);
        open(my $fifo, '\''>'\'', "${tmpdir}/backtrace") or next;
        for my $val (@array) {
            $val =~ s/^frame=//;
            my $line = "???";
            my $file = "???";
            my $content = "???";
            my %frame;
            ($err, %frame) = parse_map($err, $val);
            if (exists($frame{"line"})) {
                ($err, $line) = parse_string($err, $frame{"line"});
            }
            if (exists($frame{"fullname"})) {
                ($err, $file) = parse_string($err, $frame{"fullname"});
            }
            if ($line ne "???" and $file ne "???") {
                ($err, $content) = get_line_file($line, $file);
            }
            print $fifo "$file:$line:$content\n";
        }
        close($fifo);
    } elsif ($input =~ /^=breakpoint-(created|modified),bkpt=(.*)$/) {
        my ($operation, @command);
        $operation = $1;
        ($err, @command) = breakpoint_to_command($err, "gdb-handle-breakpoint-$operation", '\''['\'' . $2 . '\'']'\'');
        if (scalar(@command) > 0) {
            $err = send_to_kak($err, @command);
        }
    } elsif ($input =~ /^=breakpoint-deleted,(.*)$/) {
        my (%map, $id);
        ($err, %map) = parse_map($err, '\''{'\'' . $1 . '\''}'\'');
        ($err, $id)  = parse_string($err, $map{"id"});
        $err = send_to_kak($err, '\''gdb-handle-breakpoint-deleted'\'', $id);
    } elsif ($input =~ /\^done,BreakpointTable=(.*)$/) {
        my (%map, @body, @body_fixed, @command, @subcommand);
        ($err, %map) = parse_map($err, $1);
        ($err, @body) = parse_array($err, $map{"body"});
        ($err, @body_fixed) = fixup_breakpoint_table($err, @body);
        @command = ('\''gdb-clear-breakpoints'\'');
        for my $val (@body_fixed) {
            ($err, @subcommand) = breakpoint_to_command($err, '\''gdb-handle-breakpoint-created'\'', $val);
            if (scalar(@subcommand) > 0) {
                push(@command, '\'';'\'');
                push(@command, @subcommand);
            }
        }
        $err = send_to_kak($err, @command);
    } elsif ($input =~ /^\^error,msg=(.*)$/) {
        my $msg;
        ($err, $msg) = parse_string($err, $1);
        $err = send_to_kak($err, "echo", "-debug", "[gdb]", escape($msg));
    } elsif ($input =~ /^&"print (.*?)(\\n)?"$/) {
        $print_value = "$1 == ";
        $printing = 1;
    } elsif ($input =~ /^~"(.*?)(\\n)?"$/) {
        if (not $printing) { next };
        if ($1 eq '\'''\'') { next; }
        my $append;
        if ($printing == 1) {
            $1 =~ m/\$\d+ = (.*)$/;
            $append = $1;
            $printing = 2;
        } else {
            if ($print_value ne '\'''\'') {
                $print_value .= "\n";
            }
            $append = $1;
        }
        $print_value .= "$append";
    } elsif ($input =~ /\^done/) {
        if (not $printing) { next; }
        $err = send_to_kak($err, "gdb-handle-print", escape($print_value));
        $printing = 0;
        $print_value = "";
    }
    if ($err) {
        send_to_kak(0, "echo", "-debug", "[kakoune-gdb]", escape("Internal error handling this output: $input"));
    }
}
'
        } 2>/dev/null >/dev/null &
        printf "$!" > "${tmpdir}/pid"
        printf "set-option global gdb_dir '%s'\n" "$tmpdir"
        # put an empty flag of the same width to prevent the columns from jiggling
        printf "set-option global gdb_location_flag 0 '0|%${#kak_opt_gdb_location_symbol}s'\n"
        printf "set-option global gdb_breakpoints_flags 0 '0|%${#kak_opt_gdb_breakpoint_active_symbol}s'\n"
    §§
    set-option global gdb_started true
    set-option global gdb_print_client %val{client}
    gdb-set-indicator-from-current-state
    hook -group gdb global BufOpenFile .* %{
        gdb-refresh-location-flag %val{buffile}
        gdb-refresh-breakpoints-flags %val{buffile}
    }
    hook -group gdb global KakEnd .* %{
        gdb-session-stop
    }
    addhl global/gdb-ref ref -passes move gdb
§

define-command gdb-session-stop %{
    try %{
        eval %sh{ [ "$kak_opt_gdb_started" = false ] && printf fail }
        gdb-cmd quit
        nop %sh{
            #TODO: this might not be posix-compliant
            kill $(ps -o pid= --ppid $(cat "${kak_opt_gdb_dir}/pid"))
            rm -f "${kak_opt_gdb_dir}/pid" "${kak_opt_gdb_dir}/input_pipe"
            rmdir "$kak_opt_gdb_dir"
        }

        # thoroughly clean all options
        set-option global gdb_started false
        set-option global gdb_program_running false
        set-option global gdb_program_stopped false
        set-option global gdb_autojump_client ""
        set-option global gdb_print_client ""
        set-option global gdb_indicator ""
        set-option global gdb_dir ""

        set-option global gdb_breakpoints_info
        set-option global gdb_location_info
        eval -buffer * %{
            unset-option buffer gdb_location_flag
            unset-option buffer gdb_breakpoint_flags
        }
        rmhl global/gdb-ref
        remove-hooks global gdb-ref
    }
}

define-command gdb-jump-to-location %{
    eval %sh{
        eval set -- "$kak_opt_gdb_location_info"
        [ $# -eq 0 ] && exit
        line="$1"
        buffer="$2"
        printf "edit -existing \"%s\" %s\n" "$buffer" "$line"
    }
}

define-command -params 1.. gdb-cmd %{
    nop %sh{
        [ "$kak_opt_gdb_started" = false ] && exit
        IFS=' '
        printf %s\\n "$*"  > "$kak_opt_gdb_dir"/input_pipe
    }
}

define-command gdb-run -params ..    %{ gdb-cmd -exec-run %arg{@} }
define-command gdb-start -params ..  %{ gdb-cmd -exec-run --start %arg{@} }
define-command gdb-step              %{ gdb-cmd -exec-step }
define-command gdb-next              %{ gdb-cmd -exec-next }
define-command gdb-finish            %{ gdb-cmd -exec-finish }
define-command gdb-continue          %{ gdb-cmd -exec-continue }
define-command gdb-set-breakpoint    %{ gdb-breakpoint-impl false true }
define-command gdb-clear-breakpoint  %{ gdb-breakpoint-impl true false }
define-command gdb-toggle-breakpoint %{ gdb-breakpoint-impl true true }

define-command gdb-print -params ..1 %{
    try %{
        eval %sh{ [ -z "$1" ] && printf fail }
        gdb-cmd "print %arg{1}"
    } catch %{
        gdb-cmd "print %val{selection}"
    }
}

define-command gdb-enable-autojump %{
    try %{
        eval %sh{ [ "$kak_opt_gdb_started" = false ] && printf fail }
        set-option global gdb_autojump_client %val{client}
        gdb-set-indicator-from-current-state
    }
}
define-command gdb-disable-autojump %{
    set-option global gdb_autojump_client ""
    gdb-set-indicator-from-current-state
}
define-command gdb-toggle-autojump %{
    try %{
        eval %sh{ [ -z "$kak_opt_gdb_autojump_client" ] && printf fail }
        gdb-disable-autojump
    } catch %{
        gdb-enable-autojump
    }
}

declare-option -hidden int backtrace_current_line

define-command gdb-backtrace %{
    try %{
        eval %sh{
            [ "$kak_opt_gdb_stopped" = false ] && printf fail
            mkfifo "$kak_opt_gdb_dir"/backtrace
        }
        gdb-cmd -stack-list-frames
        eval -try-client %opt{toolsclient} %{
            edit! -fifo "%opt{gdb_dir}/backtrace" *gdb-backtrace*
            set buffer backtrace_current_line 0
            addhl buffer/ regex "^([^\n]*?):(\d+)" 1:cyan 2:green
            addhl buffer/ line '%opt{backtrace_current_line}' default+b
            map buffer normal <ret> ': gdb-backtrace-jump<ret>'
            hook -always -once buffer BufCloseFifo .* %{
                nop %sh{ rm -f "$kak_opt_gdb_dir"/backtrace }
                exec ged
            }
        }
    }
}

define-command -hidden gdb-backtrace-jump %{
    eval %{
        try %{
            exec -save-regs '' 'xs^([^:]+):(\d+)<ret>'
            set buffer backtrace_current_line %val{cursor_line}
            eval -try-client %opt{jumpclient} "edit -existing %reg{1} %reg{2}"
            try %{ focus %opt{jumpclient} }
        }
    }
}

define-command gdb-backtrace-up %{
    eval -try-client %opt{jumpclient} %{
        buffer *gdb-backtrace*
        exec "%opt{backtrace_current_line}gk<ret>"
        gdb-backtrace-jump
    }
    try %{ eval -client %opt{toolsclient} %{ exec %opt{backtrace_current_line}g } }
}

define-command gdb-backtrace-down %{
    eval -try-client %opt{jumpclient} %{
        buffer *gdb-backtrace*
        exec "%opt{backtrace_current_line}gj<ret>"
        gdb-backtrace-jump
    }
    try %{ eval -client %opt{toolsclient} %{ exec %opt{backtrace_current_line}g } }
}

# implementation details

define-command -hidden gdb-set-indicator-from-current-state %{
    set-option global gdb_indicator %sh{
        [ "$kak_opt_gdb_started" = false ] && exit
        printf 'gdb '
        a=$(
            [ "$kak_opt_gdb_program_running" = true ] && printf '[running]'
            [ "$kak_opt_gdb_program_stopped" = true ] && printf '[stopped]'
            [ -n "$kak_opt_gdb_autojump_client" ] && printf '[autojump]'
        )
        [ -n "$a" ] && printf "$a "
    }
}

# the two params are bool that indicate the following
# if %arg{1} == true, existing breakpoints where there is a cursor are cleared (untouched otherwise)
# if %arg{2} == true, new breakpoints are set where there is a cursor and no breakpoint (not created otherwise)
define-command gdb-breakpoint-impl -hidden -params 2 %{
    eval -draft %{
        # reduce to cursors so that we can just extract the line out of selections_desc without any hassle
        exec 'gh'
        eval %sh{
            [ "$kak_opt_gdb_started" = false ] && exit
            delete="$1"
            create="$2"
            commands=$(
                # iterating with space-splitting is safe because it's not arbitrary input
                # lucky me
                for selection in $kak_selections_desc; do
                    cursor_line=${selection%%.*}
                    match_found="false"
                    eval set -- "$kak_opt_gdb_breakpoints_info"
                    while [ $# -ne 0 ]; do
                        if [ "$4" = "$kak_buffile" ] && [ "$3" = "$cursor_line" ]; then
                            [ "$delete" = true ] && printf "delete %s\n" "$1"
                            match_found="true"
                        fi
                        shift 4
                    done
                    if [ "$match_found" = false ] && [ "$create" = true ]; then
                        printf "break %s:%s\n" "$kak_buffile" "$cursor_line"
                    fi
                done
            )
            if [ "$kak_opt_gdb_program_running" = false ] ||
                [ "$kak_opt_gdb_program_stopped" = true ]
            then
                printf "%s\n" "$commands" > "$kak_opt_gdb_dir"/input_pipe
            else
                printf "set-option global gdb_pending_commands '%s'" "$commands"
                # STOP!
                # breakpoint time
                echo "-exec-interrupt" > "$kak_opt_gdb_dir"/input_pipe
            fi
        }
    }
}


define-command -hidden -params 2 gdb-handle-stopped %{
    try %{
        gdb-process-pending-commands
        gdb-continue
    } catch %{
        set-option global gdb_program_stopped true
        gdb-set-indicator-from-current-state
        set-option global gdb_location_info  %arg{1} %arg{2}
        gdb-refresh-location-flag %arg{2}
        try %{ eval -client %opt{gdb_autojump_client} gdb-jump-to-location }
    }
}

define-command -hidden gdb-handle-stopped-unknown %{
    try %{
        gdb-process-pending-commands
        gdb-continue
    } catch %{
        set-option global gdb_program_stopped true
        gdb-set-indicator-from-current-state
    }
}

define-command -hidden gdb-handle-exited %{
    try %{ gdb-process-pending-commands }
    set-option global gdb_program_running false
    set-option global gdb_program_stopped false
    gdb-set-indicator-from-current-state
    gdb-clear-location
}

define-command -hidden gdb-process-pending-commands %{
    eval %sh{
        if [ ! -n "$kak_opt_gdb_pending_commands" ]; then
            printf fail
            exit
        fi
        printf "%s\n" "$kak_opt_gdb_pending_commands" > "$kak_opt_gdb_dir"/input_pipe
    }
    set-option global gdb_pending_commands ""
}

define-command -hidden gdb-handle-running %{
    set-option global gdb_program_running true
    set-option global gdb_program_stopped false
    gdb-set-indicator-from-current-state
    gdb-clear-location
}

define-command -hidden gdb-clear-location %{
    try %{ eval %sh{
        eval set -- "$kak_opt_gdb_location_info"
        [ $# -eq 0 ] && exit
        buffer="$2"
        printf "unset 'buffer=%s' gdb_location_flag" "$buffer"
    }}
    set global gdb_location_info
}

# refresh the location flag of the buffer passed as argument
define-command -hidden -params 1 gdb-refresh-location-flag %{
    # buffer may not exist, only try
    try %{
        eval -buffer %arg{1} %{
            eval %sh{
                buffer_to_refresh="$1"
                eval set -- "$kak_opt_gdb_location_info"
                [ $# -eq 0 ] && exit
                buffer_stopped="$2"
                [ "$buffer_to_refresh" != "$buffer_stopped" ] && exit
                line_stopped="$1"
                printf "set -add buffer gdb_location_flag '%s|%s'" "$line_stopped" "$kak_opt_gdb_location_symbol"
            }
        }
    }
}

define-command -hidden -params 4 gdb-handle-breakpoint-created %{
    set -add global gdb_breakpoints_info %arg{1} %arg{2} %arg{3} %arg{4}
    gdb-refresh-breakpoints-flags %arg{4}
}

define-command -hidden -params 1 gdb-handle-breakpoint-deleted %{
    eval %sh{
        id_to_delete="$1"
        printf "set global gdb_breakpoints_info\n"
        eval set -- "$kak_opt_gdb_breakpoints_info"
        while [ $# -ne 0 ]; do
            if [ "$1" = "$id_to_delete" ]; then
                buffer_deleted_from="$4"
            else
                printf "set -add global gdb_breakpoints_info %s %s %s '%s'\n" "$1" "$2" "$3" "$4"
            fi
            shift 4
        done
        printf "gdb-refresh-breakpoints-flags '%s'\n" "$buffer_deleted_from"
    }
}

define-command -hidden -params 4 gdb-handle-breakpoint-modified %{
    eval %sh{
        id_modified="$1"
        active="$2"
        line="$3"
        file="$4"
        printf "set global gdb_breakpoints_info\n"
        eval set -- "$kak_opt_gdb_breakpoints_info"
        while [ $# -ne 0 ]; do
            if [ "$1" = "$id_modified" ]; then
                printf "set -add global gdb_breakpoints_info %s %s %s '%s'\n" "$id_modified" "$active" "$line" "$file"
            else
                printf "set -add global gdb_breakpoints_info %s %s %s '%s'\n" "$1" "$2" "$3" "$4"
            fi
            shift 4
        done
    }
    gdb-refresh-breakpoints-flags %arg{4}
}

# refresh the breakpoint flags of the file passed as argument
define-command -hidden -params 1 gdb-refresh-breakpoints-flags %{
    # buffer may not exist, so only try
    try %{
        eval -buffer %arg{1} %{
            unset-option buffer gdb_breakpoints_flags
            eval %sh{
                to_refresh="$1"
                eval set -- "$kak_opt_gdb_breakpoints_info"
                while [ $# -ne 0 ]; do
                    buffer="$4"
                    [ "$buffer" != "$to_refresh" ] && continue
                    line="$3"
                    enabled="$2"
                    if [ "$enabled" = y ]; then
                        flag="$kak_opt_gdb_breakpoint_active_symbol"
                    else
                        flag="$kak_opt_gdb_breakpoint_inactive_symbol"
                    fi
                    printf "set -add buffer gdb_breakpoints_flags '%s|%s'\n" "$line" "$flag"
                    shift 4
                done
            }
        }
    }
}

define-command -hidden gdb-handle-print -params 1 %{
    try %{
        eval -buffer *gdb-print* %{
            set-register '"' %arg{1}
            exec gep
            try %{ exec 'ggs\n<ret>d' }
        }
    }
    try %{ eval -client %opt{gdb_print_client} 'info %arg{1}' }
}

# clear all breakpoint information internal to kakoune
define-command -hidden gdb-clear-breakpoints %{
    eval -buffer * %{ unset-option buffer gdb_breakpoints_flags }
    set-option global gdb_breakpoints_info
}
