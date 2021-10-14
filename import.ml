include Stdlib.EffectHandlers
include Stdlib.EffectHandlers.Deep

module Obj = struct
  include Obj

  let clone_continuation _ = failwith "Continuation cloning is not supported"
end
