# Cosanostra Delivery

This project simulates a delivery system built with Gleam and the OTP framework. It models core components as actors, including package management, deliverators, and navigation. The system implements two concurrency patterns:

- **Dynamic pool pattern:** Receivers are dynamically started and stopped as needed, with a configurable maximum to prevent resource exhaustion.
- **Static pool pattern:** Deliverators are started with a defined count, assigned unique names, and their restarts are tracked. Reincarnated deliverators retain their original names, preserving links defined in the supervision tree at start up.



## Supervision Tree

![Supervision Tree](src/assets/cosanostra-supervision-tree.png)


## Sequence Pseudocode
A text-based pseudocode representation of the the interactions and workflows between the main actors.

#### Legend
- `➡`: Asynchronous message sent to another actor.
- `➡➡`: Asynchronous reply from another actor.
- `->>`: Synchronous message sent to another actor.
- `-->>`: Synchronous reply from another actor.

### Receiver Pool

```
receiver_pool_sequence
    actor A as Client
    actor B as ReceiverPool
    actor C as Receiver (Worker)
    actor D as Navigator
    actor E as DistancesCache
    actor F as CoordinatesStore
    actor G as DeliveratorPool

    A->>B: ReceivePackages(packages)    
        B: Checks memoization table
        alt Batch is not memoized
            B: Spawns new Receiver
            B: Process is unlinked and monitored 
            B->>C: CalculateShortestPath(batch)
            activate C
                C➡D: GetDistance(from, to)
                activate D
                    D➡E: GetDistance(from, to)
                    E➡➡D: returns distance
                    alt If cache is a miss
                        D➡F: GetCoordinates(from)
                        F➡➡D: returns coordinates
                        D➡F: GetCoordinates(to)
                        F➡➡D: returns coordinates
                    end
                    D➡➡C: returns calculated distance
                deactivate D
                C-->>B: PathComputedSuccess(shipment)
            deactivate C
            B: Updates memoization table
        end
        B->>G: ReceivePackets(shipment)
    deactivate B
```

### Navigator

```
navigator_sequence
    actor A as Client (e.g., Receiver)
    actor B as Navigator
    actor C as DistancesCache
    actor D as CoordinatesStore

    A➡B: GetDistance(from, to)
    activate B
        B➡C: GetDistance(from, to)
        activate C
            C➡➡B: returns Result(Float, Nil)
        deactivate C
        alt Cache is a hit (Ok(dist))
            B: Returns cached distance
        else Cache is a miss (Error(Nil))
            B➡D: GetCoordinates(from)
            activate D
                D➡➡B: returns coordinates
            deactivate D
            B➡D: GetCoordinates(to)
            activate D
                D➡➡B: returns coordinates
            deactivate D
            B: Calculates new distance
        end
        B➡➡A: returns final distance
    deactivate B
```

### Deliverator Pool

```
deliverator_pool_sequence
    actor A as Client
    actor B as DeliveratorPool
    actor C as Deliverator (Worker)

    A->>B: ReceivePackets(batch)
    activate B
        B: Checks for available Deliverators
        alt If a Deliverator is Idle
            B->>C: DeliverPackets(batch)
            activate C
                loop for each packet in batch
                    C: Simulates delivery
                    C->>B: PacketDelivered(packet)
                    activate B
                        B: Removes packet from Deliverator's list
                    deactivate B
                end
                C->>B: DeliveratorSuccess()
            deactivate C
            B: Marks Deliverator as Idle
        end
    deactivate B
```

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```

## Acknowledgment

Parts of this project draw conceptual inspiration from these Elixir projects: [elhex_delivery](https://github.com/omgneering/elhex_delivery) and [warehouse](https://github.com/omgneering/warehouse). The implementation here is in Gleam, adapted to leverage its concurrency features and the OTP framework.


