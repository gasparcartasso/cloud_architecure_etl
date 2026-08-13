# Sección 01 · CUÁNTO TARDA: Cronograma y Diagrama de Gantt para Proyecto de Migración (Airflow + AWS)

## 1. Introducción y Objetivo de la Sección
Esta sección define la estimación temporal, las dependencias y la secuencia de actividades necesarias para ejecutar la migración del pipeline ETL (actualmente local en Docker) hacia una infraestructura en la nube AWS (**EC2 + S3** dentro de **MyVPC**), orquestada por **Apache Airflow**.

La representación visual mediante un **Diagrama de Gantt** permite a los evaluadores visualizar el orden cronológico, las dependencias críticas y la duración estimada de cada fase del despliegue y migración.

---

## 2. Desglose Detallado de las Etapas de Migración

La migración se estructura en **cuatro (4) etapas correlativas y secuenciales**:

### Etapa 1: Preparación (Setup / Planificación e Infraestructura)
* **Objetivo:** Preparar los scripts de aprovisionamiento, construir los artefactos necesarios y validar la configuración de AWS antes de levantar el entorno de computo.
* **Duración estimada:** 4 días hábiles

---

### Etapa 2: Prueba (Testing / Dry Run en Staging)
* **Objetivo:** Ejecutar el proceso completo de migración en un entorno de pruebas dentro de AWS para validar la conectividad de la EC2, S3 y la ejecución de DAGs en Airflow.
* **Duración estimada:** 3 días hábiles

---

### Etapa 3: Corte (Cutover / Go-Live en Producción)
* **Objetivo:** Transición definitiva del ETL local al entorno productivo en AWS EC2, minimizando la ventana de mantenimiento.
* **Duración estimada:** 1 día (Fin de semana)

---

### Etapa 4: Validación y Soporte Post-Corte (Post-Go-Live)
* **Objetivo:** Confirmar la estabilidad de los pipelines orquestados, monitorear la salud del contenedor y sanear credenciales del operador.
* **Duración estimada:** 2 días hábiles

---

## 3. Matriz de Tiempos y Dependencias (Cronograma)

| ID | Tarea / Etapa | Duración | Inicio | Fin | Dependencia Previa |
|:---|:---|:---:|:---:|:---:|:---|
| **1.0** | **Preparación (Infraestructura & Scripts)** | **4 días** | Día 1 | Día 4 | - |
| 1.1 | Script Bash de despliegue y VPC (`MyVPC`) | 2 días | Día 1 | Día 2 | - |
| 1.2 | Bucket S3 y Roles IAM (`app-role`) | 1 día | Día 3 | Día 3 | 1.1 |
| 1.3 | Configuración de credenciales bootstrap | 1 día | Día 4 | Día 4 | 1.2 |
| **2.0** | **Prueba (Dry Run en EC2 Staging)** | **3 días** | Día 5 | Día 7 | **1.0** |
| 2.1 | Despliegue de EC2 y Security Group (`MY_IP/32`) | 1 día | Día 5 | Día 5 | 1.3 |
| 2.2 | Despliegue de Docker/Airflow en EC2 | 1 día | Día 6 | Día 6 | 2.1 |
| 2.3 | Prueba de DAGs, VPC Endpoint y acceso S3 | 1 día | Día 7 | Día 7 | 2.2 |
| **3.0** | **Corte (Cutover / Go-Live)** | **1 día** | Día 8 | Día 8 | **2.0** |
| 3.1 | Data freeze local y sync a S3 | 0.3 días | Día 8 | Día 8 | 2.3 |
| 3.2 | Despliegue final en EC2 y actualización de SG | 0.4 días | Día 8 | Día 8 | 3.1 |
| 3.3 | Unpause de DAGs en Airflow (Port 8080) | 0.3 días | Día 8 | Día 8 | 3.2 |
| **4.0** | **Validación y Soporte** | **2 días** | Día 9 | Día 10 | **3.0** |
| 4.1 | Smoke test UI Airflow y monitoreo S3 | 1 día | Día 9 | Día 9 | 3.3 |
| 4.2 | Sanidad de credenciales (`userkeys.json`) | 1 día | Día 10 | Día 10 | 4.1 |

---

## 4. Diagrama de Gantt

### Diagrama Mermaid 

```mermaid
gantt
    dateFormat  YYYY-MM-DD
    title Cronograma de Migración ETL a AWS (EC2 + S3 + Airflow)

    section 1. Preparación
    Script Bash & VPC (MyVPC)       :a1, 2026-09-01, 2d
    S3 Bucket & IAM Roles           :a2, after a1, 1d
    Config Credenciales Bootstrap   :a3, after a2, 1d

    section 2. Prueba (Staging)
    Lanzamiento EC2 & SecGroup      :b1, after a3, 1d
    Despliegue Docker & Airflow     :b2, after b1, 1d
    Prueba DAGs, VPC Endpoint & S3  :b3, after b2, 1d

    section 3. Corte (Cutover)
    Data Freeze & S3 Sync           :crit, c1, after b3, 1d
    Switchover EC2 & Airflow GoLive :crit, c2, after c1, 1d

    section 4. Validación
    Smoke Tests UI Airflow & Logs   :d1, after c2, 1d
    Sanear credenciales userkeys    :d2, after d1, 1d