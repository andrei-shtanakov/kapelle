defmodule Kapelle.Product.FixtureParityTest do
  use ExUnit.Case, async: true

  alias Kapelle.Product.{Contracts, Loader, Record}

  for kind <-
        ~w(idea research_pack concept_draft product_proposal exchange_log loop_state gate_decision loop_resume_decision)a do
    describe "#{kind} fixtures" do
      test "every valid fixture loads into a typed record" do
        dir = Path.join(Contracts.dir!(unquote(kind)), "fixtures/valid")
        paths = Path.wildcard(Path.join(dir, "*.{yaml,json}"))
        assert paths != [], "no fixtures found for #{unquote(kind)} in #{dir}"

        for path <- paths do
          assert {:ok, %Record{kind: unquote(kind), doc: doc} = record} =
                   Loader.load(unquote(kind), File.read!(path)),
                 "expected #{path} to load"

          assert is_map(doc)

          assert is_binary(record.id) and record.id != "",
                 "#{path}: Record.id must come from the kind's identity field"
        end
      end

      test "every invalid fixture is a typed invalid_artifact" do
        dir = Path.join(Contracts.dir!(unquote(kind)), "fixtures/invalid")
        paths = Path.wildcard(Path.join(dir, "*.{yaml,json}"))
        assert paths != [], "no fixtures found for #{unquote(kind)} in #{dir}"

        for path <- paths do
          assert {:error, {:invalid_artifact, unquote(kind), _errors}} =
                   Loader.load(unquote(kind), File.read!(path)),
                 "expected #{path} to be rejected"
        end
      end
    end
  end

  test "unparseable YAML is a typed unparseable error, not a crash" do
    assert {:error, {:unparseable, _}} = Loader.load(:idea, ": : definitely not yaml : :")
  end

  test "duplicate key in a loaded document is a typed duplicate_key error" do
    assert {:error, {:duplicate_key, "id"}} = Loader.load(:idea, "id: A\nid: B\n")
  end
end
