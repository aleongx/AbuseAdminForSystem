# PoC | Ejecución interactiva como `NT AUTHORITY\SYSTEM` mediante una tarea programada

> **Uso previsto:** investigación de seguridad y pruebas autorizadas en un laboratorio Windows administrado. Esta documentación describe el comportamiento esperado de la prueba; el código fuente del script debe revisarse por separado antes de publicar una descripción definitiva de su implementación.

## Resumen

Esta prueba de concepto (PoC) estudia cómo una **tarea programada que se ejecuta bajo la identidad `NT AUTHORITY\SYSTEM`** puede utilizarse para iniciar un proceso en la sesión interactiva del usuario. El escenario parte de una cuenta con **pertenencia al grupo de Administradores locales**, desde la cual se evalúa el acceso al Programador de tareas y a una tarea configurada con permisos elevados.

La prueba permite observar una diferencia de seguridad importante: **ser administrador local no equivale a ser `SYSTEM`**. El resultado depende de que exista un contexto privilegiado utilizable —por ejemplo, una tarea ya configurada para ejecutarse como `SYSTEM`— y de los permisos efectivos sobre dicha tarea. El script **no obtiene por sí solo** un token `SYSTEM` a partir de un usuario estándar.

## Objetivo técnico

- Mostrar el papel de la pertenencia a **Administradores locales** en el acceso a funciones administrativas de Windows.
- Evaluar el riesgo de una **tarea programada ejecutada como `SYSTEM`** cuando usuarios con privilegios administrativos pueden iniciarla o modificarla.
- Identificar el **ID de la sesión interactiva activa**.
- Documentar cómo se utiliza ese `SessionId` para asociar el proceso generado a la sesión correcta.
- Verificar el contexto de ejecución y revisar las oportunidades de detección y endurecimiento.

## Requisitos del laboratorio

- Equipo Windows de pruebas bajo administración propia o con autorización explícita.
- Cuenta perteneciente al grupo **Administradores locales**, con permisos adecuados para el escenario.
- Acceso a **Programador de tareas** (`taskschd.msc`).
- Una tarea de laboratorio previamente configurada para ejecutarse como `SYSTEM`, si se pretende reproducir ese contexto.
- Script PowerShell de la PoC y autorización para ejecutarlo.

## Flujo de la prueba

```text
Cuenta del laboratorio (Administrador local)
             |
             v
Comprobación de permisos sobre la tarea programada
             |
             v
Tarea de laboratorio configurada para ejecutar como SYSTEM
             |
             v
Identificación del SessionId de la sesión interactiva
             |
             v
Configuración del SessionId en el script
             |
             v
Ejecución de la PoC en el entorno controlado
             |
             v
Validación del contexto de seguridad y registro de evidencia
```

## Procedimiento de laboratorio

### 1. Identificar la sesión interactiva

En una consola de Windows ejecuta:

```cmd
query user
```

Ejemplo ilustrativo (el ID **puede variar**):

```text
 USERNAME        SESSIONNAME      ID   STATE    IDLE TIME   LOGON TIME
>usuario-lab     console           2   Active   none        ...
```

Localiza la fila correspondiente a la sesión activa (`Active`) y anota el número de la columna **ID**. En el ejemplo es `2`, pero **no se debe asumir que siempre será 2**.

### 2. Revisar el valor `SessionId` en el script

Abre el archivo `.ps1` en un editor y busca el siguiente comentario, utilizado como referencia en esta versión de la PoC:

```powershell
# === CAMBIO: SessionId fijo a 2 ===
```

En el bloque correspondiente, verifica que la variable o el valor de `SessionId` coincida con el ID observado mediante `query user`. La denominación exacta de la variable depende de la implementación del script. No cambies otras partes sin revisar sus dependencias.

> **Importante:** el valor `2` es un ejemplo, no un identificador universal. Puede cambiar tras reiniciar, cerrar sesión, conectarse por RDP o cambiar de usuario.

### 3. Revisar el contexto de la tarea programada

Abre el **Programador de tareas**:

```cmd
 taskschd.msc
```

En la tarea **preparada para el laboratorio**, documenta:

1. La identidad de ejecución configurada en la tarea (por ejemplo, `SYSTEM`).
2. Los permisos efectivos de la cuenta que realiza la prueba para administrar o iniciar esa tarea.
3. La acción configurada, sus argumentos y el directorio de trabajo.
4. El historial de ejecución y los eventos registrados.

**Alcance del hallazgo:** si una cuenta administrativa puede utilizar o alterar una tarea privilegiada, la ejecución posterior ocurre con la identidad configurada en la tarea, no porque `query user` ni el comentario del script concedan privilegios. La posibilidad de modificar o iniciar una tarea depende de sus controles de acceso y de la configuración del sistema.

### 4. Configurar la acción de la tarea programada

En la tarea del laboratorio, abre **Propiedades → Acciones → Nueva** (o **Editar**, si ya existe una acción) y selecciona **Iniciar un programa**.

**Programa o script:**

```text
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
```

**Agregar argumentos (opcional):**

```text
powershell -ep bypass "C:\path\script\powershell_system.ps1"
```

Sustituye `C:\path\script\` por la ruta real del archivo `.ps1` y comprueba que la cuenta configurada en la tarea pueda leerlo.

**Nota:** los argumentos anteriores se presentan exactamente como fueron proporcionados para la PoC. La identidad efectiva del proceso depende de la configuración y los permisos de la tarea programada.

### 5. Ejecutar y validar la PoC autorizada

Ejecuta la prueba únicamente en la tarea y el equipo preparados para el laboratorio. Revisa los resultados y, en la consola abierta por el proceso de prueba, valida la identidad mediante:

```cmd
whoami
```

En una ejecución realmente realizada bajo `SYSTEM`, el resultado esperado es:

```text
nt authority\system
```

Si aparece otro usuario, el proceso no está ejecutándose con esa identidad. La presencia de una ventana interactiva, por sí sola, **no demuestra elevación de privilegios**.

## ¿Qué hace el script?

De acuerdo con el flujo técnico descrito para esta PoC, el script busca reutilizar el contexto de seguridad de un proceso o tarea que **ya opera como `SYSTEM`**, ubicar la sesión del usuario y crear un proceso visible en esa sesión. En implementaciones basadas en API de Windows, esto puede involucrar la obtención y duplicación de un token, la selección del `TokenSessionId`, la preparación de un entorno de usuario y la creación del proceso en el escritorio interactivo.

La secuencia exacta de llamadas, parámetros, nombres de variables y mecanismos de control requiere revisar el `.ps1` original. Esta documentación **no confirma** que el archivo no adjuntado implemente todas esas llamadas.

## Relevancia de seguridad

Esta PoC ilustra los riesgos derivados de la **combinación de privilegios administrativos locales, configuración de tareas programadas y reutilización de un contexto privilegiado existente**. Para análisis defensivo, conviene revisar:

- Permisos para **crear, modificar e iniciar tareas** que ejecutan cuentas privilegiadas.
- Eventos de creación o modificación de tareas (por ejemplo, **4698** y **4702** cuando su auditoría está habilitada).
- Procesos con identidad `S-1-5-18` (`SYSTEM`), especialmente cuando aparecen en una sesión interactiva y su árbol de procesos es inesperado.
- Controles de ejecución de aplicaciones, separación de privilegios y exposición de cuentas administrativas locales.
- Registro de procesos y telemetría de Microsoft Defender XDR / Microsoft Sentinel, si están disponibles.

**Nota:** que un proceso aparezca como `SYSTEM` no constituye por sí mismo una vulnerabilidad de Windows o de Intune. Para afirmar un bypass de controles se necesita especificar qué política estaba activa, cuál era el resultado esperado y cómo se validó técnicamente la desviación.

## Evidencia en video

**Demostración de la PoC:** [Ver video en YouTube](https://www.youtube.com/watch?v=VoL2-Pzr9dY)

## Aviso de uso responsable

Este material se publica con fines educativos y de evaluación defensiva. Úsalo exclusivamente en sistemas propios o donde exista autorización expresa. No se proporciona garantía sobre los resultados, que dependen de los permisos, la versión de Windows y la configuración efectiva del entorno.
