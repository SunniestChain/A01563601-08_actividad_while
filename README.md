### Actividad: Conversor de unidades interactivas

**Objetivo:** Crear un programa que convierta unidades de temperatura (Celsius a Fahrenheit y viceversa) usando un bucle `while` para un menú interactivo, una función para la lógica de conversión y sentencias `if` para manejar las opciones del usuario.

El programa debe presentar un menú con las siguientes opciones:

1.  Convertir de Celsius a Fahrenheit
2.  Convertir de Fahrenheit a Celsius
3.  Salir

La actividad tiene un valor de **10 puntos**.

-----

### Pasos para resolver la actividad

**Paso 1: Diseñar la función de conversión**
Deberás crear una función en Python. Puedes llamar a esta función `convertir_temperatura`, o el nombre que tú consideres.

  * La función debe recibir dos parámetros: el valor numérico de la temperatura a convertir y la unidad de origen (`'C'` o `'F'`).
  * Usa una sentencia `if/elif/else` dentro de la función para determinar la conversión a realizar.
  * Si la unidad es `'C'`, la fórmula para convertir a Fahrenheit es: `(temperatura * 9/5) + 32`.
  * Si la unidad es `'F'`, la fórmula para convertir a Celsius es: `(temperatura - 32) * 5/9`.
  * La función debe **regresar** el valor convertido.

**ANTES** de continuar con el siguiente paso, prueba tu función para ambas unidades origen `'C'` y `'F'`, llamándola desde tu código principal.

**Paso 2: Implementar el bucle `while` para el menú**
La lógica principal del programa debe estar dentro de un bucle `while`.

  * Crea una variable para controlar el bucle, por ejemplo, `opcion`. Iníciala con un valor que no sea '3' para que el bucle comience.
  * El bucle `while` debe ejecutarse mientras la variable `opcion` no sea '3'.
  * Dentro del bucle, imprime las opciones del menú.
  * Usa `input()` para pedir al usuario que elija una opción.

**ANTES** de continuar con el siguiente paso, prueba que tu programa termina solamente cuando la opcion sea '3', y vuelva a presentar el menú para las opciones '1' y '2'

**Paso 3: Manejar las opciones del usuario con `if`**
Dentro del bucle `while`, usa sentencias `if/elif/else` para manejar la opción elegida.

  * Si el usuario elige la opción 1, solicita la temperatura en Celsius, llama a tu función `convertir_temperatura` y muestra el resultado en pantalla.
  * Si el usuario elige la opción 2, solicita la temperatura en Fahrenheit, llama a tu función y muestra el resultado.
  * Si el usuario elige la opción 3, el bucle terminará. Muestra un mensaje de despedida.
  * Si el usuario ingresa una opción no válida, muestra un mensaje de error.

**Paso 4: Comentar el código**
Asegúrate de agregar comentarios a lo largo de tu código.

  * Cada función debe tener un comentario que explique qué hace, qué parámetros recibe y qué valor retorna.
  * Comenta las partes importantes del bucle `while` y de las sentencias `if` para explicar la lógica.

-----

### Rúbrica de evaluación (10 puntos)

| Criterio | Puntos posibles | Descripción |
| :--- | :--- | :--- |
| **Uso del bucle `while`** | 2 | Se implementa correctamente un bucle `while` para mantener el programa en ejecución hasta que el usuario decida salir. El bucle no es infinito. |
| **Uso de la función** | 3 | Se define una función (`convertir_temperatura`) que recibe parámetros y retorna un valor. La función realiza las conversiones de manera correcta. |
| **Lógica de control `if/elif/else`** | 2 | El programa utiliza sentencias condicionales para procesar correctamente las diferentes opciones del menú y manejar entradas inválidas. |
| **Solicitud de entrada** | 1 | El programa solicita y maneja la entrada del usuario de manera clara para obtener la opción del menú y los valores de temperatura. |
| **Comentarios y legibilidad** | 2 | El código está adecuadamente comentado para explicar la funcionalidad de la función y las partes clave del programa. Las variables tienen nombres descriptivos. |

-----
