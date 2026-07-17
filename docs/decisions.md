# Decision log

Registro de decisiones de arquitectura del proyecto.

## Formato (ADR)

```text
001 - Computo

Decision: En que tipo de computo corre mi aplicacion
Contexto: Ya que el ETL actualmente corre en local y esta dockerizado, la manera mas inmediata para pasarlo a correr en la nube es que se corra en EC2
Alternativas: Tambien pense en hacer un ECS
Tradeoff: Positivo - necesito menos adaptacion de mi codigo actual. Negativo - podria hacerlo mas escalable
Resultado: El ETL correra en EC2 de AWS
```

## Decisiones

001 - Computo
