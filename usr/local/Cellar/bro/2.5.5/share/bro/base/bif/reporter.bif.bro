# This file was automatically generated by bifcl from reporter.bif.

##! The reporter built-in functions allow for the scripting layer to
##! generate messages of varying severity.  If no event handlers
##! exist for reporter messages, the messages are output to stderr.
##! If event handlers do exist, it's assumed they take care of determining
##! how/where to output the messages.
##!
##! See :doc:`/scripts/base/frameworks/reporter/main.bro` for a convenient
##! reporter message logging framework.

export {
module Reporter;




## Generates an informational message.
##
## msg: The informational message to report.
##
## Returns: Always true.
##
## .. bro:see:: reporter_info
global Reporter::info: function(msg: string ): bool ;


## Generates a message that warns of a potential problem.
##
## msg: The warning message to report.
##
## Returns: Always true.
##
## .. bro:see:: reporter_warning
global Reporter::warning: function(msg: string ): bool ;


## Generates a non-fatal error indicative of a definite problem that should
## be addressed. Program execution does not terminate.
##
## msg: The error message to report.
##
## Returns: Always true.
##
## .. bro:see:: reporter_error
global Reporter::error: function(msg: string ): bool ;


## Generates a fatal error on stderr and terminates program execution.
##
## msg: The error message to report.
##
## Returns: Always true.
global Reporter::fatal: function(msg: string ): bool ;


## Generates a "net" weird.
##
## name: the name of the weird.
##
## Returns: Always true.
global Reporter::net_weird: function(name: string ): bool ;


## Generates a "flow" weird.
##
## name: the name of the weird.
##
## orig: the originator host associated with the weird.
##
## resp: the responder host associated with the weird.
##
## Returns: Always true.
global Reporter::flow_weird: function(name: string , orig: addr , resp: addr ): bool ;


## Generates a "conn" weird.
##
## name: the name of the weird.
##
## c: the connection associated with the weird.
##
## addl: additional information to accompany the weird.
##
## Returns: Always true.
global Reporter::conn_weird: function(name: string , c: connection , addl: string &default=""): bool ;

} # end of export section
module GLOBAL;