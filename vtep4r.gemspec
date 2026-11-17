require File.expand_path('vxlan/version', __dir__)

Gem::Specification.new do |s|
  s.name = 'vtep4r'
  s.version = VXLAN::VERSION
  s.authors = ['Jean-Michel Esnault']
  s.summary = 'VXLAN in Ruby: build, parse and speak it, a VTEP and an injector'
  s.description = 'A pure Ruby library to build, parse and send VXLAN (RFC 7348), ' \
                  'valid or not, for routing labs and protocol tests.'
  s.homepage = 'https://github.com/jeanmichel-gh/vtep4r'
  s.license = 'GPL-3.0-or-later'
  s.require_paths = ['.']
  s.bindir = 'exe'
  s.executables = %w[vtep4rd vtep4r-cli]
  s.required_ruby_version = '>= 3.3'
  # logger ships with Ruby, but Ruby 4.0 made it a bundled gem.
  s.add_dependency 'logger'
  s.add_dependency 'datalink-socket', '~> 1.0'
  # A test must not load this file: git ls-files fails where there is
  # no .git, as in a Docker image (bgp4r CLAUDE.md).
  s.files = `git ls-files -z`.split("\x0")
end
