project('tl-feedbackd', 'c', version: '0.1.0', meson_version: '>= 1.0.0',
  default_options: ['c_std=gnu11', 'warning_level=2'])

# Only GLib and GIO: the HTTP call to launcherctl is a plain socket write, the bus side is GDBus.
add_project_arguments('-Wno-unused-parameter', language: 'c')
glib = dependency('glib-2.0', version: '>= 2.70')
gio = dependency('gio-2.0', version: '>= 2.70')

executable('tl-feedbackd', 'main.c', 'feedback-theme.c',
  dependencies: [glib, gio], install: true, install_dir: get_option('bindir'))

# The activation file lets libfeedback (phosh, phosh-mobile-settings, GTK apps) start the daemon
# when phosh-session did not. D-Bus wants an absolute Exec, which an archive that is unpacked
# anywhere cannot know: the archive's build passes a shell line that finds it (service_exec).
exec_line = get_option('service_exec')
if exec_line == ''
  exec_line = get_option('prefix') / get_option('bindir') / 'tl-feedbackd'
endif
conf = configuration_data()
conf.set('exec', exec_line)
configure_file(input: 'data/org.sigxcpu.Feedback.service.in',
  output: 'org.sigxcpu.Feedback.service', configuration: conf,
  install: true, install_dir: get_option('datadir') / 'dbus-1' / 'services')
