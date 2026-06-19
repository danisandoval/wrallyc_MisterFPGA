# Dump the worst remaining timing paths so the failing logic can be identified.
# Run AFTER a compile:   quartus_sta -t report_paths.tcl WorldRally
# Produces failing_paths.txt in the project dir.

project_open WorldRally
create_timing_netlist
read_sdc
update_timing_netlist

set fh [open "failing_paths.txt" w]

puts $fh "==== worst 25 setup paths (all clocks) ===="
foreach_in_collection p [get_timing_paths -setup -npaths 25 -nworst 25] {
    set slack [get_path_info $p -slack]
    set from  [get_node_info [get_path_info $p -from] -name]
    set to    [get_node_info [get_path_info $p -to]   -name]
    puts $fh [format "slack %8.3f  FROM %s  TO %s" $slack $from $to]
}

puts $fh ""
puts $fh "==== setup summary by clock ===="
report_clock_fmax_summary -file fmax_summary.txt

close $fh
project_close
