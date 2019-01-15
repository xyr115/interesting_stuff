# This file was automatically generated by bifcl from /tmp/bro-20180829-84347-dlsyak/bro-2.5.5/src/input/input.bif (alternative mode).

##! Internal functions and types used by the input framework.

export {
module Input;




type Event: enum  {
	EVENT_NEW = 0,
	EVENT_CHANGED = 1,
	EVENT_REMOVED = 2,
} ;






global Input::__create_table_stream: function(description: Input::TableDescription ) : bool ;


global Input::__create_event_stream: function(description: Input::EventDescription ) : bool ;


global Input::__create_analysis_stream: function(description: Input::AnalysisDescription ) : bool ;


global Input::__remove_stream: function(id: string ) : bool ;


global Input::__force_update: function(id: string ) : bool ;






} # end of export section
module GLOBAL;