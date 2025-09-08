
# funcion fahrenheit a centigrados

def ftoc():
    fin = float(input("Grados Fahrenheit: "))
    cout = (fin-32)/1.8
    print('La temperatura en Celcuis es: ',cout)

# funcion centigrados a fahrenheit

def ctof():
    cin = float(input("Grados Celcius: "))
    fout = (cin*1.8)+32
    print('La temperatura en Fahrenheit es: ',fout)

# menu

x = int(input("Menú \n 1. (F a C) \n 2. (C a F) \n 3. (Salir) \n").strip())

# operar solo si es 1 o 2

while x != 3:
    if x == 1:
        ftoc()
    elif x == 2:
        ctof()
    else:
        print('Valor Incorrecto')
        break
    x = int(input("Menú \n 1. (F a C) \n 2. (C a F) \n 3. (Salir) \n").strip())
    
#opcion salir

if x == 3:
    print('Gracias por usar el programa')