# sdx.tcl
#
# This package is an alternative to sdx.kit's lib/sdx/sdx.tcl.  Namespaces, not
# slave interpreters, are used to sandbox the SDX scripts because the Starkit
# infrastructure is not given the opportunity to initialize slave interpreters
# to the point where SDX can function reliably.

# Create namespace variables.
namespace eval ::sdx {
    # Directory in which the SDX scripts are located.
    variable SdxDir
}

# Create stdout/stderr interception mechanism.
namespace eval ::sdx::Intercept {
    proc initialize {chan mode} {info procs}
    proc finalize {chan} {}
    proc clear {chan} {}
    proc flush {chan} {}
    proc write {chan data} {append ::sdx::Intercept::Output $data; return}
    namespace export *
    namespace ensemble create
}

# Analyze the app-sdx package.
apply {{} {
    variable ::sdx::SdxDir

    # Force all package information to be loaded.
    catch {package require {}}

    # Find the load script for the latest version of app-sdx.
    set script [package ifneeded app-sdx [lindex [lsort\
            -command {package vcompare} [package versions app-sdx]] end]]

    # Extract the directory from the app-sdx load script.
    set SdxDir [file dirname [lindex $script end]]

    # Create aliases for each available SDX command.
    foreach file [glob -tails -directory $SdxDir *.tcl] {
        if {$file ni {pkgIndex.tcl sdx.tcl}} {
            set command [file rootname $file]
            interp alias {} ::sdx::$command {} ::sdx::sdx $command
        }
    }
}}

# ::sdx::sdx --
# Invokes the SDX application as a script command.
proc ::sdx::sdx {command args} {
    variable ::sdx::Intercept::Output {} SdxDir

    # Compute name of SDX script file.
    set script [file join $SdxDir $command.tcl]

    # Confirm the SDX script exists.
    if {![file exists $script]} {
        foreach file [lsort [glob -tails -directory $SdxDir *.tcl]] {
            if {$file ni {pkgIndex.tcl sdx.tcl}} {
                lappend commands [file rootname $file]
            }
        }
        return -code error "unknown subcommand \"$command\":\
                must be [join $commands ", "]"
    }

    # Get the list of mounted filesystems.  This allows automatically unmounting
    # filesystems left mounted by SDX.
    set filesystems [vfs::filesystem info]

    # Get the list of file channels.  This allows automatically closing channels
    # left open by SDX.
    set channels [chan names]

    # Prepare to restore the current working directory, should SDX change it.
    set pwd [pwd]

    # Collect everything written to stdout and stderr into the Output variable.
    chan push stdout ::sdx::Intercept
    chan push stderr ::sdx::Intercept

    # Intercept [exit] and convert it to an error with a custom "-exit" option.
    rename ::exit ::sdx::RealExit
    set token [interp alias {} ::exit {} apply {{{exit 0}} {
        return -code error -exit $exit [string trim $::sdx::Intercept::Output]
    }}]

    # Create temporary sandbox namespace in which to execute SDX command.  This
    # namespace will collect any variables and commands created by SDX.  It is
    # kept separate from the ::sdx namespace so that commands in ::sdx (such as
    # [eval]) do not interfere with the operation of the underlying SDX command.
    namespace eval ::sdx::Sandbox [list set argv0 [list ::sdx::sdx $command]]
    namespace eval ::sdx::Sandbox [list set argv $args]

    # Prepare to handle SDX errors.
    set options {-code return}
    try {
        # Run the requested SDX script.
        namespace eval ::sdx::Sandbox [list source $script]
    } on error {value options} {
        # Handle errors and intercepted [exit], which was converted to an error.
        if {![dict exists $options -exit]} {
            set Output $value\n$Output
        } elseif {[dict get $options -exit]} {
            set Output "SDX exit code [dict get $options -exit]\n$Output"
        } else {
            dict set options -code return
        }
    } finally {
        # Delete sandbox namespace.
        namespace delete ::sdx::Sandbox

        # Restore original [exit] command.
        interp alias {} $token {}
        rename ::sdx::RealExit ::exit

        # Stop intercepting stdout/stderr.
        chan pop stdout
        chan pop stderr

        # Return to the original working directory.
        cd $pwd

        # Close leftover channels.
        foreach chan [chan names] {
            if {$chan ni $channels} {
                chan close $chan
            }
        }

        # Unmount leftover filesystems.
        foreach filesystem [vfs::filesystem info] {
            if {$filesystem ni $filesystems} {
                vfs::filesystem unmount $filesystem
            }
        }
    }

    # The return value is the intercepted stdout/stderr text.
    dict set options -level 0
    return {*}$options [string trim $Output[set Output {}]]
}

# vim: set sts=4 sw=4 tw=80 et ft=tcl:
