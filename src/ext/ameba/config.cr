# TODO: remove this monkey-patch
class Ameba::Config
  property sources : Array(Source) { previous_def }
end
