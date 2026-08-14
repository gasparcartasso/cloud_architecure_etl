# Decision Log

Registro de decisiones de arquitectura del proyecto.

## Formato (ADR)

```
NNN - Título

Decision: qué se decidió
Contexto: por qué se llegó a esta encrucijada
Alternativas: qué otras opciones se evaluaron
Tradeoff: qué se gana y qué se pierde con la decisión tomada
Resultado: qué se implementó finalmente
```

---

## Decisiones

### 001 - Computo

```
Decision: En que tipo de computo corre mi aplicacion
Contexto: Ya que el ETL actualmente corre en local y esta dockerizado, la manera mas inmediata para pasarlo a correr en la nube es que se corra en EC2
Alternativas: Tambien pense en hacer un ECS
Tradeoff: Positivo - necesito menos adaptacion de mi codigo actual. Negativo - podria hacerlo mas escalable
Resultado: El ETL correra en EC2 de AWS
```

### 002 - Almacenamiento

```
Decision: Donde se almacenan los datos/artefactos que produce y consume el ETL
Contexto: El ETL necesita un almacenamiento durable, accesible desde la instancia de computo y desacoplado del ciclo de vida de esta
Alternativas: Disco local/EBS de la instancia, EFS compartido, S3
Tradeoff: Positivo - S3 es durable, barato, y no ata los datos al ciclo de vida de la instancia EC2. Negativo - agrega latencia de red respecto a un disco local y requiere manejar permisos IAM en vez de simples permisos de filesystem
Resultado: Los datos se almacenan en un bucket S3 (articlewriterstorage-...) en la misma region que la instancia
```

### 003 - Identidad y acceso de la instancia a S3

```
Decision: Cómo se autentica la instancia EC2 para leer/escribir en el bucket S3
Contexto: La aplicación necesita interactuar con S3 y requiere autenticarse mediante credenciales específicas inyectadas o configuradas en la instancia
Alternativas: Asignar un IAM Role con Instance Profile a la instancia EC2 para credenciales temporales automáticas
Tradeoff: Positivo - permite un control directo mediante claves inyectadas/proporcionadas a la EC2 acotadas por una IAM Policy específica. Negativo - al depender de Access Keys/Secret Keys explícitas, requiere gestionar la custodia y posible rotación manual de secretos en la EC2, aumentando el riesgo de fuga si las claves se exponen en el código o en la instancia
Resultado: La instancia EC2 accede al bucket S3 utilizando Access Key y Secret Key configuradas directamente en la instancia, cuyas acciones están acotadas a través de una IAM Policy de S3
```

### 004 - Credenciales de aprovisionamiento (bootstrap)

```
Decision: Como se autentica el script de despliegue contra la API de AWS
Contexto: El script corre desde la maquina del operador (fuera de AWS) y necesita crear/gestionar recursos antes de que exista ningun rol de instancia
Alternativas: AWS SSO / credenciales temporales via AssumeRole, perfiles de aws configure con MFA
Tradeoff: Positivo - usar userkeys.json (Access Key/Secret estaticos) es rapido de implementar y no requiere infraestructura de SSO previa. Negativo - son credenciales de larga duracion, guardadas en un archivo plano, sin rotacion automatica; es el eslabon mas debil de identidad de todo el diseño
Resultado: El script lee Access Key/Secret desde userkeys.json y los configura via aws configure; pendiente migrar a credenciales temporales o SSO
```

### 005 - Topología de red

```
Decision: Como se organiza la red donde corre el ETL
Contexto: Se necesita aislar la instancia de computo, permitir salida a Internet solo donde sea necesario, y dejar preparado un espacio para futuros componentes que no deban ser publicos
Alternativas: Correr todo en la VPC default de la cuenta, o usar una unica subred publica sin segmentacion
Tradeoff: Positivo - una VPC propia con subred publica (para la EC2) y subred privada (reservada a futuro) da control total de ruteo y aisla lo que no necesita salir a Internet. Negativo - mas recursos que mantener (route tables, IGW, endpoint) frente a usar la VPC default
Resultado: Se crea MyVPC (10.0.0.0/16) con una subred publica (10.0.1.0/24, az-2a) y una privada (10.0.2.0/24, az-2b), cada una con su propia route table
```

### 006 - Acceso de la subred privada a S3

```
Decision: Como llegan a S3 los recursos que en el futuro vivan en la subred privada, sin salir a Internet
Contexto: La subred privada no tiene ruta 0.0.0.0/0, por lo que sin nada adicional no podria alcanzar S3
Alternativas: Agregar un NAT Gateway en la subred publica para dar salida a Internet a la subred privada
Tradeoff: Positivo - un VPC Endpoint tipo Gateway hacia S3 es gratuito y mantiene el trafico dentro de la red de AWS, sin exponerlo a Internet. Negativo - solo cubre S3 (y DynamoDB); si en el futuro se necesita otro servicio AWS o Internet general desde la subred privada, igual va a hacer falta un NAT Gateway
Resultado: Se crea un VPC Endpoint Gateway hacia com.amazonaws.ap-southeast-2.s3, asociado a la route table privada
```

### 007 - Acceso remoto a la instancia

```
Decision: Como se administra/accede a la instancia EC2 desde afuera
Contexto: Se necesita poder conectarse a la instancia para operarla (SSH) y acceder a la UI del orquestador (Airflow, puerto 8080)
Alternativas: AWS Systems Manager Session Manager (sin puerto abierto ni llave), un bastion host separado, un Security Group abierto a 0.0.0.0/0
Tradeoff: Positivo - abrir el Security Group solo a la IP publica actual del operador (MY_IP/32) en los puertos 22 y 8080 es simple y no requiere infraestructura adicional. Negativo - la IP del operador cambia (redes dinamicas, otros operadores, oficinas distintas), lo que obliga a re-ejecutar el script para actualizar la regla, y el puerto 22 sigue expuesto a Internet aunque sea a una sola IP
Resultado: Security Group MySecGroupPub con reglas de ingreso a 22 y 8080 limitadas a MY_IP/32; llave de acceso via EC2 Key Pair (MyKeyPair.pem) regenerada en cada despliegue
```

### 008 - Aprovisionamiento de la infraestructura

```
Decision: Con que herramienta se define y despliega la infraestructura
Contexto: Se necesita poder crear y recrear el entorno de forma repetible
Alternativas: Terraform, CloudFormation/CDK
Tradeoff: Positivo - un script bash con AWS CLI es inmediato de escribir y no requiere aprender una nueva herramienta ni gestionar estado remoto. Negativo - no hay estado versionado ni plan de cambios; la idempotencia depende de checks manuales (if/describe) escritos a mano en el script, lo que es fragil y dificil de mantener a medida que crece la infraestructura
Resultado: El despliegue se hace con un script bash que usa AWS CLI directamente, con chequeos manuales de existencia de cada recurso antes de crearlo
```
