rookieide_sources = [
  'main.vala',
]

rookieide_deps = [
  dependency('gtk4'),
  dependency('libadwaita-1'),
  dependency('gtksourceview-5'),
  dependency('vte-2.91-gtk4'),
]

executable('rookieide', rookieide_sources,
  dependencies: rookieide_deps,
  install: true,
)
gtk_dep = dependency('gtk4', version: '>= 4.10')
adw_dep = dependency('libadwaita-1', version: '>= 1.4')
gtksource_dep = dependency('gtksourceview-5', version: '>= 5.6')
vte_dep = dependency('vte-2.91-gtk4', required: false)

vala_args = []
deps = [gtk_dep, adw_dep, gtksource_dep]

if vte_dep.found()
  vala_args += ['-D', 'HAVE_VTE']
  deps += [vte_dep]
endif

executable(
  'rookie-ide',
  ['main.vala'],
  vala_args: vala_args,
  dependencies: deps,
  install: true
)
