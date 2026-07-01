
sources = [
  'action-handles.vala',
  'application.vala',
  'config.vapi',
  'main.vala',
  'gst/ape-demux.c',
  'gst/gst-player.vala',
  'gst/peak-calculator.vala',
  'gst/tag-parser.vala',
  'ui/dialogs.vala',
  'ui/leaflet.vala',
  'ui/mini-bar.vala',
  'ui/music-list.vala',
  'ui/music-widgets.vala',
  'ui/narrow-bar.vala',
  'ui/paintables.vala',
  'ui/peak-bar.vala',
  'ui/play-bar.vala',
  'ui/play-panel.vala',
  'ui/queue-sheet.vala',
  'ui/sleep-timer.vala',
  'ui/playlist-dialog.vala',
  'ui/preferences.vala',
  'ui/stable-label.vala',
  'ui/store-panel.vala',
  'ui/taglist-dialog.vala',
  'ui/volume-button.vala',
  'ui/window.vala',
  'lyrics/models.vala',
  'lyrics/parser.vala',
  'lyrics/http.vala',
  'lyrics/cache.vala',
  'lyrics/provider-info.vala',
  'lyrics/engine.vala',
  'lyrics/providers/paxsenix.vala',
  'lyrics/providers/betterlyrics.vala',
  'lyrics/providers/simpmusic.vala',
  'lyrics/providers/lyricsplus.vala',
  'lyrics/providers/lrclib.vala',
  'lyrics/providers/netease.vala',
  'lyrics/providers/megalobiz.vala',
  'lyrics/providers/genius.vala',
  'lyrics/providers/musixmatch.vala',
  'lyrics/providers/musicbrainz.vala',
  'lyrics/lyrics-sheet.vala',
  'utils/discord-rpc.vala',
  'utils/async-task.vala',
  'utils/cover-cache.vala',
  'utils/data-io.vala',
  'utils/dir-cache.vala',
  'utils/dir-monitor.vala',
  'utils/mpris.vala',
  'utils/music.vala',
  'utils/music-library.vala',
  'utils/music-loader.vala',
  'utils/playlist-file.vala',
  'utils/portal.vala',
  'utils/tag-cache.vala',
  'utils/thumbnailer.vala',
]

conf = configuration_data()
conf.set_quoted('APP_ID', app_id)
conf.set_quoted('CODE_NAME', meson.project_name())
conf.set_quoted('VERSION', version)
conf.set_quoted('LOCALEDIR', get_option('prefix') / get_option('localedir'))
configure_file(output: 'config.h', configuration: conf)

c_name = meson.project_name()
res_name = c_name + '-resources'

sources += gnome.compile_resources(res_name,
  'gresource.xml',
  c_name: c_name
)

add_project_arguments('-I' + meson.current_source_dir () + '/gst/', language: 'c')

executable(c_name, sources,
  vala_args: [
    # meson.current_source_dir () + '/config.vapi',
    meson.current_source_dir () + '/gst/gst-ext.vapi',
  ],
  dependencies: dependencies,
  install: true,
)
