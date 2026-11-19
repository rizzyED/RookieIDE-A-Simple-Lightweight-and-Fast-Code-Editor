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