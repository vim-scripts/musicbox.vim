" Music Box music player in vim 
"
" Copyright (c) 2008 Nicolas Bigeard
" ga6ri3l@gmail.com 
"
" Version 1.0 May 2008
" Base functionality
"
" usage :
" to try the plugin, just do :
"
" tabe playlist.txt
" r !ls -d /home/user/music/album/*
" the go on a file and press c-h to play
" c-j to pause
" c-k to stop 
" c-n to play next file in list
" c-p to play previous file in list
if exists('loaded_plugin_musicbox')
    finish
endif
let loaded_plugin_musicbox = 1

if version < 700
    echo "musicbox.vim plugin requires Vim 7 or above"
    finish
endif

if !has('python')
    s:ErrMsg( "Error: Required vim compiled with +python" )
    finish
endif


python << EOF
import pygst
pygst.require('0.10')
import gst, time, os

class GSTPlayer():
    """
        Gstreamer engine
    """

    def __init__(self):
        self.playing = False
        self.connections = []
        self.last_position = 0
        self.eof_func = None
        self.tag_func = None
        self.setup_playbin()
        self._sink_element_factories = []
        self.ok = 0

    def setup_playbin(self):
        self.playbin = gst.element_factory_make('playbin')
        self.bus = self.playbin.get_bus()
        self.bus.add_signal_watch()
        self.bus.enable_sync_message_emission()
        self.audio_sink = None

    def set_volume(self, vol):
        """
            Sets the volume for the player
        """
        self.playbin.set_property('volume', vol)

    def _get_gst_state(self):
        """
            Returns the raw GStreamer state
        """
        return self.playbin.get_state(timeout=50*gst.MSECOND)[1]

    def get_state(self):
        """
            Returns the player state: 'playing', 'paused', or 'stopped'.
        """
        state = self._get_gst_state()
        if state == gst.STATE_PLAYING:
            return 'playing'
        elif state == gst.STATE_PAUSED:
            return 'paused'
        else:
            return 'stopped'

    def is_playing(self):
        """
            Returns True if the player is currently playing
        """
        return self._get_gst_state() == gst.STATE_PLAYING

    def is_paused(self):
        """
            Returns True if the player is currently paused
        """
        return self._get_gst_state() == gst.STATE_PAUSED

    def on_message(self, bus, message, reading_tag = False):
        """
            Called when a message is received from gstreamer
        """
        if message.type == gst.MESSAGE_TAG and self.tag_func:
            self.tag_func(message.parse_tag())
        elif message.type == gst.MESSAGE_EOS and not self.is_paused() \
            and self.eof_func:
            self.eof_func()
        elif message.type == gst.MESSAGE_ERROR:
            print message, dir(message)

        return True

    def __notify_source(self, o, s, num):
        s = self.playbin.get_property('source')
        s.set_property('device', num)
        self.playbin.disconnect(self.notify_id)

    def set_audio_sink(self, sink=None):
        """
            Sets the audio sink up.  It tries the passed in value, and if that
            doesn't work, it tries autoaudiosink
        """

        self.audio_sink = self._create_sink(sink)

        # if the audio_sink is still not set, use a fakesink
        if not self.audio_sink:
            print('Audio sink could not be set up.  Using a fakesink '
               'instead.  Audio will not be available.')
            self.audio_sink = gst.element_factory_make('fakesink')

        self.playbin.set_property('audio-sink', self.audio_sink)

    def _create_sink(self, sink=None):
        """
            Creates an element: equalizer -> replaygain -> named sink.

            If the named sink is None, use the audio_sink setting.
            The equalizer and ReplayGain elements are optional and will not be
            created if they don't exist or are disabled.
        """

        sink = 'autoaudiosink'
        try:
            asink = gst.element_factory_make(sink)
        except:
            print("Could not create sink %s.  Trying autoaudiosink." %
                sink)
            asink = gst.element_factory_make('autoaudiosink')

        sinkbin = gst.Bin()
        sink_elements = []

        # iterate through sink element factory list
        for element_factory in self._sink_element_factories:
            if element_factory.is_enabled(self):
                # This should be made a try: except: statement in case creation fails
                sink_elements += element_factory.get_elements(self)
                print(element_factory.name + " support initialized.")
            else:
                print("Not using " + element_factory.name + " disabled by the user")

        # if still empty just use asink and end
        if not sink_elements:
            return asink

        # otherwise put audiosink as last element
        sink_elements.append(asink)

        # add elements to sink and link them
        sinkbin.add(*sink_elements)
        gst.element_link_many(*sink_elements)

        # create sink pad in that links to sink pad of first element
        sinkpad = sink_elements[0].get_static_pad('sink')
        sinkbin.add_pad(gst.GhostPad('sink', sinkpad))

        return sinkbin


    def play(self, uri):
        """
            Plays the specified uri
        """
        if not self.audio_sink:
            self.set_audio_sink('')
        
        if not self.connections and not self.is_paused() and not uri == None and not\
            uri.find("lastfm://") > -1:

            self.connections.append(self.bus.connect('message', self.on_message))
            self.connections.append(self.bus.connect('sync-message::element',
                self.on_sync_message))

            if '://' not in uri: 
                if not os.path.isfile(uri):
                    raise Exception('File does not exist: ' + uri)
                uri = 'file://%s' % uri # FIXME: Wrong.
            uri = uri.replace('%', '%25')

            # for audio cds
            if uri.startswith("cdda://"):
                num = uri[uri.find('#') + 1:]
                uri = uri[:uri.find('#')]
                self.notify_id = self.playbin.connect('notify::source',
                    self.__notify_source, num)

            self.playbin.set_property('uri', uri.encode('utf-8'))

        self.playbin.set_state(gst.STATE_PLAYING)

    def on_sync_message(self, bus, message):
        """
            called when gstreamer requests a video sync
        """
        if message.structure.get_name() == 'prepare-xwindow-id' and \
            VIDEO_WIDGET:
            print('Gstreamer requested video sync')
            VIDEO_WIDGET.set_sink(message.src)

    def seek(self, value, wait=True):
        """
            Seeks to a specified location (in seconds) in the currently
            playing track
        """
        value = int(gst.SECOND * value)

        if wait: self.playbin.get_state(timeout=50*gst.MSECOND)
        event = gst.event_new_seek(1.0, gst.FORMAT_TIME,
            gst.SEEK_FLAG_FLUSH|gst.SEEK_FLAG_ACCURATE,
            gst.SEEK_TYPE_SET, value, gst.SEEK_TYPE_NONE, 0)

        res = self.playbin.send_event(event)
        if res:
            self.playbin.set_new_stream_time(0L)
        else:
            print("Couldn't send seek event")
        if wait: self.playbin.get_state(timeout=50*gst.MSECOND)

        self.last_seek_pos = value

    def pause(self):
        """
            Pauses the currently playing track
        """
        self.playbin.set_state(gst.STATE_PAUSED)

    def toggle_pause(self):
        if self.is_paused():
            self.playbin.set_state(gst.STATE_PLAYING)
        else:
            self.playbin.set_state(gst.STATE_PAUSED)

    def stop(self):
        """
            Stops the playback of the currently playing track
        """
        for connection in self.connections:
            self.bus.disconnect(connection)
        self.connections = []

        self.playbin.set_state(gst.STATE_NULL)

    def get_position(self):
        """
            Gets the current playback position of the playing track
        """
        if self.is_paused(): return self.last_position
        try:
            self.last_position = \
                self.playbin.query_position(gst.FORMAT_TIME)[0]
        except gst.QueryError:
            self.last_position = 0

        return self.last_position

    def set_buffer(self,buf,row):
        """
            Set current buffer for later operation
        """
        self.buffer = buf
        self.row = row
        self.ok = 1

    def get_next(self):
        self.row = self.row+1
        if self.row > len(self.buffer):
            self.row = self.row-1

        return self.buffer[self.row-1]

    def get_previous(self):
        self.row = self.row-1
        if self.row < 1:
            self.row = 1
        return self.buffer[self.row-1]
    

musicboxplayer = GSTPlayer()

import vim
def PlayFile():
    print("play")
    (row,col) = vim.current.window.cursor
    cb = vim.current.buffer
    line = cb[row-1]
    musicboxplayer.set_buffer(cb,row)
    try:
        musicboxplayer.play(line)
    except Exception, e:
        print e

def PlayNextFileInBuffer():
    if musicboxplayer.ok==0:
        return
    print("next..")
    line = musicboxplayer.get_next()
    if musicboxplayer.get_state == 'stopped':
        musicboxplayer.play(line)
    else :
        musicboxplayer.stop()
        musicboxplayer.play(line)
    
def PlayPreviousFileInBuffer():
    if musicboxplayer.ok==0:
        return
    print("previous..")
    line = musicboxplayer.get_previous()
    if musicboxplayer.get_state == 'stopped':
        musicboxplayer.play(line)
    else :
        musicboxplayer.stop()
        musicboxplayer.play(line)
    

def PauseFile():
    print("pause")
    try:
        musicboxplayer.pause()
    except Exception, e:
        print e

def StopFile():
    print("stop")
    try:
        musicboxplayer.stop()
    except Excpetion, e:
        print e
EOF

fun! PlayFile()
    python PlayFile()
endfun

fun! PauseFile()
    python PauseFile()
endfun

fun! StopFile()
    python StopFile()
endfun

fun! PlayNextFileInBuffer()
    python PlayNextFileInBuffer()
endfun

fun! PlayPreviousFileInBuffer()
    python PlayPreviousFileInBuffer()
endfun

map <c-h> :call PlayFile()<cr>
map <c-j> :call PauseFile()<cr>
map <c-k> :call StopFile()<cr>
map <c-n> :call PlayNextFileInBuffer()<cr>
map <c-p> :call PlayPreviousFileInBuffer()<cr>
