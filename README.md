check_ica_servers
=================

Check the Citrix Metaframe XP service by completing an HTTP dialogue with a Program
Neigbourhood server (pn_server) that returns an ICA server in the named Server farm
hosting the specified applications (an ICA server in a farm which runs some MS app).
Ask as many times as necessary to find out how many different ICA servers offer the
application.


### Requirements

* Perl libraries; Nagios::Plugins utils.pm

### Usage

    check_ica_servers.pl
    [-P | --pn_server]    The name or address of the Citrix Metaframe XP
                          Program Neigbourhood server (required).
    [-A | --pub_app]      The name of an application published by the server farm 
                          (default 'Word 2003').
    [-F | --server_farm]  The name of a Citrix Metaframe XP server farm. (required)
    [-m | --maximum]      The maximum number of ICA servers that could offer the
                          service in total (required).
    [-w | --warning]      If less or equal servers offered the result will be warning.
    [-c | --critical]     If less or equal servers offered the result will be critical.
    [-M | --max_requests] Don't send more requests than specified.
    [-t | --timeout]      Timeout as usual in seconds.
    [-v | --verbose]      Level of verbosity
    [-h | --help]         The help text an usage.
    [-x | --xml_debug]    Print XML requests and answers.
    [-V | --version]      Print version of the plugin.
    
    example:
    ./check_ica_servers.pl -P pnserver -A windows -F farm -w 20 -c 25 -m 28 -M 200 -t 5 


