# El usuario de prueba

**Cómo funciona y cómo se construyó, en simple.**

Noviembre de 2026 · orbital.net.ar · Máximo Bertaina y Gonzalo Castellano

---

## La idea en una frase

Escaneás un QR —o tocás **Probar** en la landing— y entrás al banco **sin
registrarte**, con una cuenta que ya tiene plata y movimientos. Podés hacer de
todo. Al salir, se borra.

Lo pidió la cátedra como cierre de regularización: *"un usuario test, una
persona cualquiera, que al leer un QR ya lo haga cliente del banco, que esa
cuenta ya tenga dinero, que tenga movimientos, y que deje simular determinadas
cuestiones sin que impacte en el dinero real"*.

---

## Lo que hay que entender primero

Había dos formas de hacer esto, y son trabajos completamente distintos:

- **Una maqueta:** pantallas que parecen el banco, con datos escritos a mano.
- **Un sandbox:** el banco de verdad, con datos que se tiran.

Elegimos el **sandbox**, porque el pedido dice que el usuario *"pueda hacer
absolutamente todo"*. Entonces la regla es:

> **No aislamos el sistema, aislamos los datos.**

El visitante usa los mismos endpoints, las mismas validaciones y los mismos
cálculos de interés que un cliente real. Lo único distinto es que su cuenta
vive en un espacio que después se borra.

Eso explica todas las decisiones que siguen.

---

## Cómo entra, sin Clerk

```
QR  →  /demo  →  el backend crea la sesión  →  token  →  el portal
```

El token viaja por **el mismo header** que usa Clerk (`Authorization: Bearer`).
No inventamos uno nuevo: el CORS del backend sólo deja pasar tres headers, y
uno nuevo lo bloquearía el navegador antes de salir.

En el backend hay un middleware que mira el token. Si empieza con `orbdemo_`,
resuelve la sesión de prueba; si no, se lo pasa a Clerk **sin tocarlo**. En los
dos casos deja `req.usuarioActual` con **la misma forma exacta**.

Esa es la clave de todo: de ahí para abajo, el 100 % del sistema no se entera
de la diferencia.

### Por qué no hicimos un `/api/demo/*` paralelo

Porque habría que duplicar cada endpoint, y entonces lo que se prueba no es el
banco sino una copia del banco. Un solo camino de código.

---

## Dónde viven los datos

En **las mismas tablas**, con una marca `es_demo` en la persona.

Esto es lo más lindo del diseño: como todo el backend **ya filtraba por
`persona_id`**, el aislamiento salió casi gratis. No hubo que tocar ni una
consulta de lectura. Lo único que se filtró son los tres lugares donde una
persona de prueba no debe aparecer: el listado del personal del banco, los
reportes, y las consultas que hablan con el Banco Central.

---

## Cómo no sale al Banco Central

El Central es un ambiente **compartido con todo el curso**: una transferencia
de verdad queda registrada allá, y eso rompe el "no impacta en nada".

Hay una función, `elCentral(usuarioActual)`, que devuelve el Central real o uno
**simulado** según quién esté operando. Los lugares que llamaban a
`centralBankService.x(…)` ahora llaman a `elCentral(usuarioActual).x(…)`. El
simulado responde lo mismo, con la misma forma, sin salir a internet.

---

## Los dos mundos no se tocan

Este fue el problema menos obvio y el más grave.

Si el visitante tipeaba el CBU de **un cliente real**, el flujo encontraba esa
cuenta como destino y **le acreditaba plata de verdad**. Y al revés: si un
cliente real le transfiere a una cuenta de prueba, esa plata desaparece cuando
la sesión se borra.

Ahora, si la cuenta destino está del otro lado, se trata como si no existiera
acá y la transferencia sale por el camino interbancario —que para el demo es
simulado.

Lo mismo pasa con el **QR de cobros**, y es un escenario muy realista: en una
presentación, alguien le muestra a la sesión de prueba el QR de un cliente
real. Si se pagara, esa plata entraría de verdad.

---

## Qué arranca cargado

| | |
|---|---|
| Caja en pesos | **$850.000** (principal) |
| Caja en dólares | **US$ 1.200** |
| Movimientos | **13**, de los últimos dos meses |
| Agenda | **3 contactos** |

Los movimientos usan los tipos y canales que **ya existían** en el catálogo:
sueldo, pagos de servicio, recarga de celular, consumos de tarjeta,
transferencias en las dos direcciones, compra de dólares y la bonificación de
bienvenida. Nada inventado para el demo.

Los tres contactos tienen CBU de otro banco a propósito, para que la
transferencia funcione de punta a punta sin poder tocar una cuenta real.

---

## Cómo se borra

Borrar la persona **no alcanza**: la cascada choca contra `bonificaciones`,
`transacciones`, `cobros` y las claves de préstamos y plazos fijos hacia
`cuentas`. Hay un orden obligado:

```
cobros → bonificaciones → transacciones → plazos_fijos → prestamos
       → cuentas → personas  (y ahí sí cascadea el resto)
```

Todo en una transacción, con un seguro al final: el borrado de la persona lleva
`AND es_demo = TRUE`. Si algún día alguien llama a esa función con el id
equivocado, no borra un cliente real.

Se dispara de dos formas: el botón **"Salir y borrar mis datos"**, y una tarea
de fondo que cada 10 minutos barre las sesiones vencidas. El TTL es de **45
minutos**.

---

## Qué puede y qué no

| Puede | No puede |
|---|---|
| Transferir dentro y fuera del banco | Ver o tocar datos de un cliente real |
| Comprar y vender dólares | Hacer que entre o salga plata real |
| Pagar servicios y recargar el celular | Llegar a las secciones internas |
| Pedir tarjeta y préstamo, y que se los aprueben solos | Salir al Banco Central |
| Hacer un plazo fijo, cobrar y escanear QR, usar el chatbot | |

El rol `cliente` está **escrito en el middleware**, no leído de la base: ni un
INSERT equivocado en `personas_roles` le da permisos internos.

---

## Qué código compartido hubo que tocar

1. **`cobros-router`** montaba su propio middleware de Clerk y rechazaba el
   token de prueba, así que el botón "Cobrar" fallaba. Ahora lo deja pasar y
   saltea los pasos de Clerk, incluida la reverificación —que para una
   identidad que no existe en Clerk no tiene nada que revalidar.
2. **El pago de QR** ahora exige que las dos cuentas estén del mismo lado.
3. **`/auth/perfil`** está fuera de `/api` y es la primera llamada del portal.
   Sin arreglarlo, el visitante entraba y quedaba mirando el spinner para
   siempre.

---

## Cómo sabemos que funciona

**438 tests** entre los dos repos, y cada tanda se verificó **saboteando el
código a propósito**: si al romper algo los tests siguen pasando, no sirven.

Y una prueba contra la base real con **un espía puesto sobre el Banco Central**
que tira si alguien lo llama: se cuenta cuántas filas hay, se crea la sesión,
se opera, se cierra, y se vuelve a contar. Los números tienen que dar
**idénticos**.

En la primera corrida el espía marcó **una** llamada al Central real. Era una
función que busca el nombre del banco destino, que corre fuera de la
transacción, y a la que me había olvidado de pasarle el usuario. Lo insidioso
es que tiene un `try/catch` que devuelve `null` si el Central no responde, así
que **el error se tragaba solo** y la transferencia se veía perfecta. Sin el
espía no lo agarraba nadie.

### Verificado en producción

Crea la sesión, carga el perfil, muestra las cuentas con los saldos correctos,
devuelve **403** si intenta listar otras personas, cierra la sesión y el token
queda muerto (**401**).

---

## Dónde está el código

| Archivo | Qué hace |
|---|---|
| `src/middlewares/autenticar.js` | La puerta: acepta las dos credenciales |
| `src/modules/demo-service.js` | Crear, buscar, borrar y barrer sesiones |
| `src/modules/demo-router.js` | Los tres endpoints |
| `src/modules/el-central.js` | Elige qué Banco Central le toca |
| `src/modules/central-bank-simulado.js` | El Central de mentira |
| `src/modules/limpiador-de-demos.js` | La tarea de fondo |
| `prisma/migrations/3_modo_demo/` | La migración |
| `banco-frontend/src/features/demo/` | Entrada, cartel y API |
| `banco-frontend/src/hooks/useSesion.ts` | Unifica Clerk y prueba |
| `banco-landing/src/componentes/Prueba.tsx` | La sección con el QR |

---

*Banco Orbital — Máximo Bertaina y Gonzalo Castellano · 2026*
