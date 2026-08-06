defmodule Kapelle.Executor.ChainAdapter do
  @moduledoc """
  `Kapelle.Executor.Adapter` implementation running single-prompt tasks
  against a real langchain-backed model, resolved from the routed
  `Decision.target` via `Kapelle.Providers.ModelFactory`.

  Only single-prompt tasks are supported: `task[:prompt]` must be a
  string. Makes real network calls — exercised only by the opt-in
  `@tag :provider_smoke` test, never by the default suite.
  """

  @behaviour Kapelle.Executor.Adapter

  alias Kapelle.Executor.Result
  alias Kapelle.Providers.ModelFactory
  alias LangChain.Chains.LLMChain
  alias LangChain.Message
  alias LangChain.Utils.ChainResult

  @impl true
  def execute(%{id: task_id, prompt: prompt}, decision) when is_binary(prompt) do
    with {:ok, model} <- ModelFactory.build(model_id(decision)),
         {:ok, output} <- run_chain(model, prompt) do
      {:ok, Result.new!(%{task_id: task_id, status: :pass, output: %{"text" => output}})}
    end
  end

  def execute(%{id: _task_id}, _decision), do: {:error, :missing_prompt}

  defp model_id(%{target: %{provider: provider, model: model}}), do: "#{provider}@#{model}"

  defp run_chain(model, prompt) do
    %{llm: model, messages: [Message.new_user!(prompt)]}
    |> LLMChain.new!()
    |> LLMChain.run()
    |> ChainResult.to_string()
    |> case do
      {:ok, output} -> {:ok, output}
      {:error, _chain, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, {:chain_exception, exception}}
  end
end
