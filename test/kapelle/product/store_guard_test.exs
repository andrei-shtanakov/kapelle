defmodule Kapelle.Product.StoreGuardTest do
  use Kapelle.DataCase, async: false

  alias Kapelle.Product.{Contracts, Loader, Store}

  defp rp_record do
    {:ok, record} =
      Loader.load(
        :research_pack,
        File.read!(
          Path.join(
            Contracts.dir!(:research_pack),
            "fixtures/valid/rp-001.yaml"
          )
        )
      )

    record
  end

  test "put/2 refuses inside an ambient transaction" do
    record = rp_record()

    Application.put_env(:kapelle, :sandbox?, false)
    on_exit(fn -> Application.put_env(:kapelle, :sandbox?, true) end)

    {:ok, result} = Repo.transaction(fn -> Store.put(record, "LOOP-G1") end)
    assert result == {:error, :ambient_transaction}
  end
end
