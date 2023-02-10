project('mempooled', 'd',
    version: '0.3.1'
)

mempooled_build_versions = []

mempooled_src = [
    'source/mempooled/dynamic.d',
    'source/mempooled/fixed.d',
    'source/mempooled/intrinsics.d',
    'source/mempooled/package.d'
]

mempooled_lib = static_library(
    'mempooled',
    mempooled_src,
    include_directories: include_directories('source'),
    d_module_versions: mempooled_build_versions
)

mempooled_dep = declare_dependency(
    include_directories: include_directories('source'),
    link_with: mempooled_lib
)

test_exe = executable(
    'mempooled-test',
    mempooled_src,
    include_directories: include_directories('source'),
    d_args: ['-betterC', '-unittest'],
    link_args: ['-link-defaultlib-shared=false']
)
test('bctest', test_exe)
