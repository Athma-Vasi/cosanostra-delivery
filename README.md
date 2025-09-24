# cosanostra_delivery

This project simulates a delivery system built with Gleam and the OTP framework. It models core components as actors, including package management, deliverators, and navigation. The system leverages two concurrency patterns:

- **Dynamic pool pattern:** Deliverators are dynamically started and stopped as needed, with a configurable maximum to prevent resource exhaustion.
- **Static pool pattern:** Receivers are assigned unique names, and their restarts are tracked. Reincarnated receivers retain their original identity, enabling robust state management.

![Supervision Tree](src/assets/cosanostra-supervision-treedrawio.png)



## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```
