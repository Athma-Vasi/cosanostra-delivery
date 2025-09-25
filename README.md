# Cosanostra Delivery

This project simulates a delivery system built with Gleam and the OTP framework. It models core components as actors, including package management, deliverators, and navigation. The system implements two concurrency patterns:

- **Dynamic pool pattern:** Receivers are dynamically started and stopped as needed, with a configurable maximum to prevent resource exhaustion.
- **Static pool pattern:** Deliverators are started with a defined count, assigned unique names, and their restarts are tracked. Reincarnated deliverators retain their original names, preserving links defined in the supervision tree.



## Supervision Tree

![Supervision Tree](src/assets/cosanostra-supervision-tree.png)


## Sequence Pseudocode

### Receiver Pool

```
sequence_pseudocode
    participant A as Client
    participant B as ReceiverPool
    participant C as Receiver (Worker)
    participant D as Navigator
    participant E as DistancesCache
    participant F as CoordinatesStore
    participant G as DeliveratorPool

    A->>B: receive_packages(packages)
    activate B
        B->>B: Checks memoization table
        alt Batch is not memoized
            B->>C: Spawns new Receiver
            C->>B: process is monitored and unlinked
            B->>C: calculate_shortest_path(batch)
            activate C
                C->>D: get_distance(from, to)
                activate D
                    D->>E: get_distance(from, to)
                    E-->>D: returns distance
                    alt If cache is a miss
                        D->>F: get_coordinates(from)
                        F-->>D: returns coordinates
                        D->>F: get_coordinates(to)
                        F-->>D: returns coordinates
                    end
                    D-->>C: returns calculated distance
                deactivate D
                C-->>B: path_computed_success(shipment)
            deactivate C
            B->>B: Updates memoization table
        end
        B->>G: receive_packets(shipment)
    deactivate B
```


### Deliverator Pool

```
sequence_pseudocode
    participant A as Client
    participant B as DeliveratorPool
    participant C as Deliverator (Worker)

    A->>B: receive_packets(batch)
    activate B
        B->>B: Checks for available Deliverators
        alt If a Deliverator is Idle
            B->>C: deliver_packets(batch)
            activate C
                loop for each packet in batch
                    C->>C: Simulates delivery
                    C->>B: packet_delivered(packet)
                    activate B
                        B->>B: Removes packet from Deliverator's list
                    deactivate B
                end
                C->>B: deliverator_success()
            deactivate C
            B->>B: Marks Deliverator as Idle
        end
    deactivate B
```

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```
