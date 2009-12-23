require 'rubygems'
require 'eventmachine'

module PRMilter

	MILTER_VERSION = 2 # Milter version we claim to speak (from pmilter)

	# Potential milter command codes and their corresponding PpyMilter callbacks.
	# From sendmail's include/libmilter/mfdef.h
	SMFIC_ABORT   = 'A' # "Abort"
	SMFIC_BODY    = 'B' # "Body chunk"
	SMFIC_CONNECT = 'C' # "Connection information"
	SMFIC_MACRO   = 'D' # "Define macro"
	SMFIC_BODYEOB = 'E' # "final body chunk (End)"
	SMFIC_HELO    = 'H' # "HELO/EHLO"
	SMFIC_HEADER  = 'L' # "Header"
	SMFIC_MAIL    = 'M' # "MAIL from"
	SMFIC_EOH     = 'N' # "EOH"
	SMFIC_OPTNEG  = 'O' # "Option negotation"
	SMFIC_RCPT    = 'R' # "RCPT to"
	SMFIC_QUIT    = 'Q' # "QUIT"
	SMFIC_DATA    = 'T' # "DATA"
	SMFIC_UNKNOWN = 'U' # "Any unknown command"

	COMMANDS = {
		SMFIC_ABORT =>  'abort',
		SMFIC_BODY =>  'body',
		SMFIC_CONNECT =>  'connect',
		SMFIC_MACRO =>  'macro',
		SMFIC_BODYEOB =>  'end_body',
		SMFIC_HELO =>  'helo',
		SMFIC_HEADER =>  'header',
		SMFIC_MAIL =>  'mail_from',
		SMFIC_EOH =>  'end_headers',
		SMFIC_OPTNEG =>  'opt_neg',
		SMFIC_RCPT =>  'rcpt_to',
		SMFIC_QUIT =>  'quit',
		SMFIC_DATA =>  'data',
		SMFIC_UNKNOWN =>  'unknown',
	}

	NO_CALLBACKS = 127  # (all seven callback flags set: 1111111)
	CALLBACKS = {
		'connect' =>     1,  # 0x01 SMFIP_NOCONNECT # Skip SMFIC_CONNECT
		'helo' =>        2,  # 0x02 SMFIP_NOHELO    # Skip SMFIC_HELO
		'mail_from' =>    4,  # 0x04 SMFIP_NOMAIL    # Skip SMFIC_MAIL
		'rcpt_to' =>      8,  # 0x08 SMFIP_NORCPT    # Skip SMFIC_RCPT
		'body' =>        16, # 0x10 SMFIP_NOBODY    # Skip SMFIC_BODY
		'header' =>      32, # 0x20 SMFIP_NOHDRS    # Skip SMFIC_HEADER
		'end_headers' =>  64, # 0x40 SMFIP_NOEOH     # Skip SMFIC_EOH
	}

	# Acceptable response commands/codes to return to sendmail (with accompanying
	# command data).  From sendmail's include/libmilter/mfdef.h
	RESPONSE = {
		'ADDRCPT'     =>  '+', # SMFIR_ADDRCPT    # "add recipient"
		'DELRCPT'     =>  '-', # SMFIR_DELRCPT    # "remove recipient"
		'ACCEPT'      =>  'a', # SMFIR_ACCEPT     # "accept"
		'REPLBODY'    =>  'b', # SMFIR_REPLBODY   # "replace body (chunk)"
		'CONTINUE'    =>  'c', # SMFIR_CONTINUE   # "continue"
		'DISCARD'     =>  'd', # SMFIR_DISCARD    # "discard"
		'CONNFAIL'    =>  'f', # SMFIR_CONN_FAIL  # "cause a connection failure"
		'ADDHEADER'   =>  'h', # SMFIR_ADDHEADER  # "add header"
		'INSHEADER'   =>  'i', # SMFIR_INSHEADER  # "insert header"
		'CHGHEADER'   =>  'm', # SMFIR_CHGHEADER  # "change header"
		'PROGRESS'    =>  'p', # SMFIR_PROGRESS   # "progress"
		'QUARANTINE'  =>  'q', # SMFIR_QUARANTINE # "quarantine"
		'REJECT'      =>  'r', # SMFIR_REJECT     # "reject"
		'SETSENDER'   =>  's', # v3 only?
		'TEMPFAIL'    =>  't', # SMFIR_TEMPFAIL   # "tempfail"
		'REPLYCODE'   =>  'y', # SMFIR_REPLYCODE  # "reply code etc"
	}

	MILTER_LEN_BYTES = 4  # from sendmail's include/libmilter/mfdef.h

	ACTION_ADDHDRS    = 1  # 0x01 SMFIF_ADDHDRS    # Add headers
	ACTION_CHGBODY    = 2  # 0x02 SMFIF_CHGBODY    # Change body chunks
	ACTION_ADDRCPT    = 4  # 0x04 SMFIF_ADDRCPT    # Add recipients
	ACTION_DELRCPT    = 8  # 0x08 SMFIF_DELRCPT    # Remove recipients
	ACTION_CHGHDRS    = 16 # 0x10 SMFIF_CHGHDRS    # Change or delete headers
	ACTION_QUARANTINE = 32 # 0x20 SMFIF_QUARANTINE # Quarantine message

	class Milter
		def initialize
			@body = ''
		end

		def opt_neg( ver, actions, protocol )
			_actions = 0b110000000
			_protocol = ACTION_CHGBODY
			return SMFIC_OPTNEG + [ MILTER_VERSION, _actions, _protocol].pack("NNN") 
		end

		def header( k,v )
			return Response.continue
		end

		def body( data )
			@body << data
			return Response.continue
		end

		class Response
			class << self
				def continue
					RESPONSE['CONTINUE']
				end

				def replace_body( body )
					RESPONSE["REPLBODY"] + body + "\0"
				end
			end
		end
	end

	class MilterConnectionHandler < EM::Connection
		@@milter_class = Milter

		def initialize
			@data = ''
			@milter = @@milter_class.new
		end

		def send_milter_response( res )
			r = [ res.size ].pack('N') + res
			send_data(r)
		end

		def parse_opt_neg( data )
			ver, actions, protocol = data.unpack('NNN')
			return [ver, actions, protocol]
		end

		def parse_macro( data )
			macro, val  = data[0].chr, data[1..-1]
			return [macro, val]
		end

		def parse_connect( data )
			hostname, val = data.split("\0", 2)
			family = val[0].unpack('C')
			port = val[1...3].unpack('n')
			address = val[3..-1]
			return [hostname, family, port, address]
		end

		def parse_helo( data )
			return [data]
		end

		def parse_mail_from( data )
			mailfrom, esmtp_info = data.split("\0", 2 )
			return [mailfrom, esmtp_info.split("\0")]
		end

		def parse_rcpt_to( data )
			mailfrom, esmtp_info = data.split("\0", 2 )
			return [mailfrom, esmtp_info.split("\0")]
		end

		def parse_header( data )
			k,v = data.split("\0", 2)
			return [k, v.delete("\0")]
		end

		def parse_end_headers( data )
			return []
		end

		def parse_body( data )
			return [ data.delete("\0") ]
		end

		def parse_end_body( data )
			return []
		end

		def prase_quit( data )
			return []
		end

		def parse_abort( data )
			return []
		end

		def receive_data( data )
			@data << data
			while @data.size >= MILTER_LEN_BYTES
				pkt_len = @data[0...MILTER_LEN_BYTES].unpack('N').first
				if @data.size >= MILTER_LEN_BYTES + pkt_len
					@data.slice!(0, MILTER_LEN_BYTES)
					pkt = @data.slice!(0, pkt_len)
					cmd, val = pkt[0].chr, pkt[1..-1] 

					if cmd == SMFIC_QUIT
						close_connection
						return
					end

					if COMMANDS.include?(cmd) and @milter.respond_to?(COMMANDS[cmd])
						method_name = COMMANDS[cmd]
						args = []
						args = self.send('parse_' + method_name, val ) if self.respond_to?('parse_' + method_name )
						ret = @milter.send(method_name, *args )

						next if cmd == SMFIC_MACRO

						if not ret.is_a? Array
							ret = [ ret ]
						end

						ret.each do |r|
							send_milter_response(r)
						end
					else
						next if cmd == SMFIC_MACRO
						send_milter_response(RESPONSE['CONTINUE'])
					end
				else
					break
				end
			end
		end

		class << self
			def register( milter_class )
				@@milter_class = milter_class
			end
		end
	end

	class << self
		def register( milter_class )
			MilterConnectionHandler.register(milter_class)
		end

		def start( host = 'localhost', port = 8888 )
			EM.run do
				EM.start_server host, port, MilterConnectionHandler
			end
		end
	end
end

if $0 == __FILE__
	# example
	# change mail body
	class MyMilter < PRMilter::Milter
		def header( k,v )
			puts "#{k} => #{v}"
			return Response.continue
		end

		def end_body( *args )
			puts "BODY => #{@body}"
			return [Response.replace_body("hogehoge"), Response.continue]
		end
	end

	PRMilter.register(MyMilter)
	PRMilter.start
end
