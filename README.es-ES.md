

# ProcessHub

![example workflow](https://github.com/alfetahe/process-hub/actions/workflows/elixir.yml/badge.svg)  [![hex.pm version](https://img.shields.io/hexpm/v/coverex.svg?style=flat)](https://hex.pm/packages/process_hub) [![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/process_hub)

## Descripción

Biblioteca para construir sistemas distribuidos escalables. Se encarga de la distribución de
procesos dentro de un clúster de nodos, mientras proporciona un registro de procesos sincronizado globalmente.

ProcessHub se encarga de iniciar, detener y monitorear los procesos en el clúster.
Escala automáticamente cuando se actualiza el clúster y maneja particiones de red.

ProcessHub ofrece diferentes opciones de configuración para definir si opera en una
arquitectura **descentralizada** o **basada en un líder**. La estrategia de distribución predeterminada es
descentralizada y se basa en hashing consistente, donde cada nodo del clúster se considera
igual. Alternativamente, puedes configurar ProcessHub para utilizar una estrategia de balanceador de carga
centralizada que depende de un nodo líder para tomar decisiones de distribución basadas en métricas
del clúster en tiempo real.

> #### ProcessHub es eventualmente consistente {: .info}
> ProcessHub está diseñado pensando en la escalabilidad y la disponibilidad. 
> La mayoría de las operaciones son asincrónicas y no bloqueantes. Puede garantizar **consistencia eventual**.
>
> El sistema puede no estar en un estado consistente en todo momento, 
> pero eventualmente convergerá a un estado consistente.

## Características

Las características principales incluyen:
- Distribuir procesos automáticamente o manualmente dentro de un clúster de nodos.
- Registro de procesos distribuido y sincronizado para consultas rápidas.
- Monitoreo de procesos y reinicio automático ante fallos (`Supervisor`).
- Transferencia del estado del proceso durante su migración.
- Proporciona diferentes estrategias listas para usar que manejan: 
  - Migraciones de procesos.
  - Distribución de procesos.
  - Sincronización de procesos.
  - Replicación de procesos.
  - Particionamiento del clúster.
- Hooks (ganchos) para disparar eventos en acciones específicas y extender la funcionalidad.
- Formación y recuperación automáticas del clúster del hub cuando los nodos se unen o abandonan el clúster.
- Personalizable y extensible para modificar el comportamiento predeterminado del sistema implementando controladores de hooks y estrategias personalizados.
- Registro opcional respaldado en disco (DETS) que sobrevive al reinicio del coordinador en un solo nodo — activar mediante `:registry_backend`. Ver [Persistencia](guides/Persistence.md).

## Instalación

1. Agrega `process_hub` a tu lista de dependencias en `mix.exs`:

    ```elixir
    def deps do
      [
        {:process_hub, "~> 0.6.0"}
      ]
    end
    ```

2. Ejecuta `mix deps.get` para obtener las dependencias.    

3. Agrega `ProcessHub` al árbol de supervisión de tu aplicación:

    ```elixir
    defmodule MyApp.Application do
      use Application

      def start(_type, _args) do
        children = [
          ProcessHub.child_spec(%ProcessHub{hub_id: :my_hub})
        ]

        opts = [strategy: :one_for_one, name: MyApp.Supervisor]
        Supervisor.start_link(children, opts)
      end
    end
    ```
  Es posible iniciar múltiples hubs bajo el mismo árbol de supervisión, cada uno
  con un `:hub_id` único.
  Al hacerlo, cada hub tendrá su propio clúster de procesos. 
  Todos los hubs serán independientes entre sí.

  Por ejemplo, podemos iniciar dos hubs separados con diferentes configuraciones.

## Creación dinámica de procesos
Crea dinámicamente 2 procesos distribuidos bajo el hub `:my_hub`. Estos procesos se
inician de forma asincrónica por defecto y son monitoreados por el hub.

```elixir
iex> ProcessHub.start_children(:my_hub, [
  %{id: "process1", start: {MyProcess, :start_link, [nil]}},
  %{id: "process2", start: {MyProcess, :start_link, [nil]}}
])
{:ok, :start_initiated}
```

## Creación estática de procesos
Inicia el hub con 2 `child_specs`. El hub iniciará los procesos al arrancar.

```elixir
child_specs = [
  %{
    id: "my_process_1",
    start: {MyProcess, :start_link, [nil]}
  },
  %{
    id: "my_process_2",
    start: {MyProcess, :start_link, [nil]}
  }
]

# Start under the supervision tree.
ProcessHub.child_spec(%ProcessHub{
  hub_id: :my_hub,
  child_specs: child_specs
})
```

## Búsqueda de procesos

Consulta todo el registro para todos los procesos bajo el hub `:my_hub`:
```elixir
iex> ProcessHub.process_list(:my_hub, :global)
[
  {"my_process_1", [node_two@host: #PID<23772.233.0>]},
  {"my_process_2", [node_one@user: #PID<0.250.0>]}
]
```

Consulta procesos por `child_id`:
```elixir
iex> ProcessHub.child_lookup(:my_hub, "my_process_1")
{
  %{id: "my_process_1", start: {MyProcess, :start_link, [nil]}},
  [node_two@host: #PID<0.228.0>]
}
```

Encuentra el `pid` de un proceso por `child_id`:
```elixir
iex> ProcessHub.get_pid(:my_hub, :my_process_1)
#PID<0.228.0>
```

## Configuración

ProcessHub se ejecuta con valores predeterminados adecuados: `%ProcessHub{hub_id: :my_hub}` es una
configuración completa y válida. El comportamiento se personaliza a través de la
estructura `%ProcessHub{}` (ver `t:ProcessHub.t/0`), lo que te permite cambiar las
estrategias de distribución, migración, sincronización, replicación y tolerancia a particiones,
y opcionalmente respaldar el registro de procesos en disco.

```elixir
ProcessHub.child_spec(%ProcessHub{
  hub_id: :my_hub,
  # Migrate process state to the target node during redistribution.
  migration_strategy: %ProcessHub.Strategy.Migration.HotSwap{},
  # Run each process on 2 nodes for redundancy.
  redundancy_strategy: %ProcessHub.Strategy.Redundancy.Replication{replication_factor: 2},
  # Stay available only while a quorum of nodes is connected.
  partition_tolerance_strategy: %ProcessHub.Strategy.PartitionTolerance.StaticQuorum{quorum_size: 2},
  # Persist the registry to disk so a single-node restart keeps its children.
  registry_backend: {:dets, path: "priv/my_hub.dets"}
})
```

Consulta [guías/Configuración.md](guides/Configuration.md) para el conjunto completo de
opciones, y [guías/Persistencia.md](guides/Persistence.md) para el registro opcional
respaldado en disco y la recuperación del coordinador.

## Comenzar 📚

¿Eres nuevo en ProcessHub? **Comienza con la [guía de introducción](https://hexdocs.pm/process_hub/introduction.html)** — te guiará a través de la instalación, configuración y tus primeros procesos distribuidos.

Explora la [documentación completa](https://hexdocs.pm/process_hub) para todas las guías y la referencia de la API.

## Contribuir
Las contribuciones son bienvenidas y apreciadas. Si tienes alguna idea, sugerencia o error que reportar,
por favor abre un issue o un pull request en GitHub.
