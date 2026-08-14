defmodule Kapelle.Product.SchemaCwdIndependenceTest do
  use ExUnit.Case, async: false

  alias Kapelle.Product.{Contracts, Validator}

  # Owner's S2 preamble, item 3: production loads schemas via
  # Application.app_dir; this test proves loading works when the OS CWD is
  # NOT the repo root. priv/ is packaged into releases by construction —
  # a full `mix release` smoke is deferred until the repo grows a release
  # config (controller ruling recorded in the plan).
  test "schemas resolve and validate with the process CWD outside the repo" do
    tmp = System.tmp_dir!()
    old = File.cwd!()

    try do
      File.cd!(tmp)
      :persistent_term.erase({Kapelle.Product.Contracts, :idea})
      assert %ExJsonSchema.Schema.Root{} = Contracts.schema!(:idea)

      assert {:error, {:invalid_artifact, :idea, _}} =
               Validator.validate(:idea, %{"nonsense" => true})
    after
      File.cd!(old)
    end
  end
end
