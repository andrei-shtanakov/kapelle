defmodule Kapelle.Product.Oracle.NormalizerTest do
  use ExUnit.Case, async: true

  alias Kapelle.Product.Oracle.Normalizer

  # Hand-picked, byte-copied raw trace events from the committed golden run
  # (test/support/fixtures/golden/happy/raw-trace.jsonl at generation time) —
  # kept literal here so the unit tests stay meaningful even if the golden
  # fixture is later regenerated with different hashes/artifact ids.

  @researcher_artifact_written %{
    "event" => "artifact_written",
    "key" => "LOOP-001:0:researcher",
    "kind" => "research-pack",
    "artifact" => "RP-001",
    "output_hash" => "sha256:bf726281050cdee117573f69d5ea9640bdbaa00aad2f947717afa06d51d44eb2"
  }

  @creator_artifact_written %{
    "event" => "artifact_written",
    "key" => "LOOP-001:1:creator",
    "kind" => "concept-draft",
    "artifact" => "CD-002",
    "output_hash" => "sha256:30aa2b5a2533e0335ede78390974866015c621cf794a3049c35a4d31359f95a9"
  }

  @transition_event %{
    "event" => "transition",
    "from" => "draft",
    "to" => "in_iteration",
    "proposal_version" => 2
  }

  @continue_verdict %{
    "event" => "verdict",
    "iteration" => 0,
    "verdict" => "continue",
    "reason" => "open: 2 critical(s), 1 request(s)"
  }

  @ready_verdict %{
    "event" => "verdict",
    "iteration" => 1,
    "verdict" => "ready_for_business",
    "reason" => "no open critical assumptions/gaps and no open requests"
  }

  @delta_applied %{
    "event" => "delta_applied",
    "iteration" => 0,
    "concept_draft" => "CD-001",
    "proposal_version" => 3
  }

  test "version is v1" do
    assert Normalizer.version() == "v1"
  end

  test "a researcher artifact_written normalizes iteration/stage from the key and hyphenated kind/ref" do
    assert Normalizer.normalize([@researcher_artifact_written]) == [
             %{
               "iteration" => 0,
               "stage" => "researcher",
               "artifact_kind" => "research_pack",
               "artifact_ref" => "research-pack://RP-001",
               "artifact_hash" =>
                 "sha256:bf726281050cdee117573f69d5ea9640bdbaa00aad2f947717afa06d51d44eb2"
             }
           ]
  end

  test "a creator artifact_written normalizes concept-draft kind/ref at a later iteration" do
    assert Normalizer.normalize([@creator_artifact_written]) == [
             %{
               "iteration" => 1,
               "stage" => "creator",
               "artifact_kind" => "concept_draft",
               "artifact_ref" => "concept-draft://CD-002",
               "artifact_hash" =>
                 "sha256:30aa2b5a2533e0335ede78390974866015c621cf794a3049c35a4d31359f95a9"
             }
           ]
  end

  test "a transition combines from/to into a single proposal_transition" do
    assert Normalizer.normalize([@transition_event]) == [
             %{"proposal_transition" => "draft->in_iteration"}
           ]
  end

  test "a verdict reason with a colon is truncated to its leading clause, never the raw counts" do
    assert Normalizer.normalize([@continue_verdict]) == [
             %{"iteration" => 0, "verdict" => "continue", "stop_reason_class" => "open"}
           ]
  end

  test "a verdict reason with no colon keeps the whole reason as the class" do
    assert Normalizer.normalize([@ready_verdict]) == [
             %{
               "iteration" => 1,
               "verdict" => "ready_for_business",
               "stop_reason_class" => "no open critical assumptions/gaps and no open requests"
             }
           ]
  end

  test "delta_applied and other technical events are discarded entirely" do
    assert Normalizer.normalize([@delta_applied]) == []
  end

  test "a mixed sequence keeps only domain observations, in order" do
    assert Normalizer.normalize([
             @transition_event,
             @researcher_artifact_written,
             @delta_applied,
             @continue_verdict
           ]) == [
             %{"proposal_transition" => "draft->in_iteration"},
             %{
               "iteration" => 0,
               "stage" => "researcher",
               "artifact_kind" => "research_pack",
               "artifact_ref" => "research-pack://RP-001",
               "artifact_hash" =>
                 "sha256:bf726281050cdee117573f69d5ea9640bdbaa00aad2f947717afa06d51d44eb2"
             },
             %{"iteration" => 0, "verdict" => "continue", "stop_reason_class" => "open"}
           ]
  end

  test "normalize is deterministic: repeated calls on the same input are byte-identical" do
    raw = [@transition_event, @researcher_artifact_written, @continue_verdict, @ready_verdict]
    first = Jason.encode!(Normalizer.normalize(raw))
    second = Jason.encode!(Normalizer.normalize(raw))
    assert first == second
  end
end
