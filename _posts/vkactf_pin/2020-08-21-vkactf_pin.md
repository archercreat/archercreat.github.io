---
title: Решение одного таска с помощью pin
date: 2020-08-21 23:04:00 +07:00
tags: [Intel PIN]
---

В этой статье я попробую описать не стандартный ход решения одной проблемы с помощью pintool.

# Задача

Нам необходимо 10000 раз выиграть в игре сапер. Поле игры - 24х24 с 99 минами. Все мины хранятся в константом массиве размера 99 * 10000 * 2 * 4 байт. После прохождения 10000 игр, нам выдается победный флаг.

Декомпилированный код игры:

```c++
void play(void)
{
  char board[25];
  char board_[25];

  int magic = 0;
  for (int i = 0; i <= 9999; ++i )
  {
    printf("New game_%d: \n", i);
    int win = 0;
    int empty_cells = SIDE * SIDE - MINES;
    initialise(board, board_);
    placemines(MinesAll[99 * i], board);
    int is_first_move = 0;
    while ( !win )
    {
      clear();
      printf("Current game_%d: \n", i);
      printboard(board_);
      make_move(&row, &col);
      if ( !is_first_move && ismine(row, col, board) )
        replacemine(row, col, board);
      magic += row + col;
      ++is_first_move;
      win = playminesuntil(board_, board, MinesAll[99 * i], row, col, &empty_cells);
      if ( win )
        return;
      if ( !empty_cells )
      {
        printf("\nVictory, but still to win_%d !\n", 10000 - i);
        win = 1;
      }
    }
  }
  printf("VKACTF{");
  magic = 58 * (1337 * magic % 0xFFFFFF);
  int v7 = (magic + 7) % 49 + 28;
  for (int j = 0; j < v7; ++j )
  {
    for (int k = 0; k < v7 * v7 / 2 / v7; ++k )
    {
      char v6 = inter[j * (v7 * v7 / 2 / v7) + k];
      int v5 = (magic >> k);
      v5 ^= v6;
      std::cout << (char)v5;
    }
  }
  puts("}");
}
```

# Проблема

Можно заметить, что флаг, который расшифровывается после победы, зависит от значения переменной `magic`, которая, в свою очередь равна `magic += row + col`, где row - строка, col - столбец введенной нами клетки.

Конечно, мы можем статично посчитать чему равна эта переменная, сложив все строки и столбцы свободных клеток на поле. Но из-за того, что после выбора клетки, прилежащие к ней клетки тоже открываются и их уже вводить не надо, задача становится нетривиальной.

# PIN

Pin - это фреймворк для динамической инструментации прогаммного кода для x86 и x86_x64 архитектур.
Пин предоставляет обширный набор апи для любого типа инструментации, единственное ограничение - наше воображение.

Большинство апи можно разделить на следующие категории:

|Модуль|	Описание|
|-----|---------|
|IMG|	Для работы с образами программ в памяти|
|RTN|	Для работы с функциями|
|SEC	|Для работы с секциями|
|INS|	Для работы с инструкциями|
|REG|	Для работы с регистрами|


Подбронее про пин можно прочесть [тут](https://software.intel.com/sites/landingpage/pintool/docs/98223/Pin/html/modules.html).

# Идея

Нужно сделать так, чтобы программа сама решала какие ячейки открывать без ввода значений от пользователя.

Для этого неотходимо изменить функцию `make_move` в коде программы.

```c++
void make_move(int *row, int *col)
{
  printf("\nYour move, (row, column) >> ");
  scanf("%d %d", row, col);
}
```

Так же нам нужно знать, в какой момент мы выиграли и в какой момент началась новая игра. Для этого будем использовать функцию `printf` как наш oracle.
Мы создадим вектор всех мин во всех полях и при начале новой игры (нового поля) будем генерировать вектор свободных ячеек для этого поля.

# Решение

Для начала, поскольку массив мин константен и лежит в памяти, сдампим его на диск для дальнейшего использования в нашем pintool.

Для этого в Иде выполним следующий код:

```python
import idaapi
mines = idaapi.get_many_bytes(0x203020, 99 * 2 * 4 * 10000)
open('mines.bin','wb').write(mines)
```

Напишем функцию, которая загружает мины из файла и сохраняет их в вектор в виде пары строка столбец:

```c++
vector<pair<int, int>> v_mines;

void load_mines()
{
    char *memblock;
    int size;
    // open file from disk and read it
    ifstream file("mines.bin", ios::in|ios::binary|ios::ate);
    if (!file.is_open())
    {
        logg << "[-] unable to read mines.bin" << endl;
        exit(-1);
    }
    size = file.tellg();
    memblock = new char [size];
    file.seekg(0, ios::beg);
    file.read(memblock, size);
    file.close();
    logg << "[+] mines are in memory." << endl;

    // memblock -> arr of ints.
    auto mines = (int*)memblock;
    // basic check just to be sure it was loaded correctly
    assert(mines[0] == 20);
    // fill v_mines vector
    for (int i = 0; i < m_size; i += 2)
        v_mines.push_back(make_pair(mines[i], mines[i+1]));

    logg << "[+] " << v_mines.size() << " mines are loaded." << std::endl;
    delete[] memblock;
}
```

Теперь напишем алгоритм, который будет находить все свободные ячейки для текущего поля.

```c++
const int field_size = 24;
vector<pair<int, int>> solution;
// k - field (from 0 up to 9999)
int k_field = 0;
// field to make operations on
char field[field_size][field_size];

void fill()
{
    auto st = v_mines.begin() + (k_field * 99);
    auto cur_mines = vector<pair<int, int>>(st, st + 99);
    for (auto &i : cur_mines)
        field[i.first][i.second] = 1;
}

void clear_field()
{
    for (int i = 0; i < field_size; i++)
        for (int j = 0; j < field_size; j++)
            field[i][j] = 0;
}

void generate_solution()
{
    solution.clear();
    clear_field();
    fill();
    for (int i = 0; i < field_size; i++)
        for (int j = 0; j < field_size; j++)
            if (!field[i][j])
                solution.push_back(make_pair(i, j));
}
```

Все что осталось сделать - заменить функцию `make_move` и хукнуть функцию `printf`.

Хуки будем делать в коллбэке загрузки новых модулей. Пин позволяет регистрировать свой коллбэк, который будет вызывать при загрузки новых модулей в процесс.

Регистрируем коллбэк:

```c++
IMG_AddInstrumentFunction(ImageLoad, 0);
```

```c++
/*
Called on every image that was loaded.
 */
VOID ImageLoad(IMG img, VOID *v)
{
    logg << "loaded:\t" << IMG_Name(img) << std::endl;

    // we replace make_move function in main executable
    if (IMG_IsMainExecutable(img))
    {
        auto imageBase = IMG_LowAddress(img);
        // address of make_move in memory
        auto funcAddr  = imageBase + 0xb67;

        auto rtn = RTN_FindByAddress(funcAddr);
        if (RTN_Valid(rtn))
        {
            // replace 
            RTN_Replace(rtn, AFUNPTR(make_move));
            logg << "[+] make_move hijacked." << std::endl; 
            MineSweeper::load_mines();
        }
    }

    // we will use printf as an oracle, so we hook it as well
    // notice that we are not replacing it, but just hooking before the call.
    auto rtn = RTN_FindByName(img, "printf");
    if (RTN_Valid(rtn))
    {
        RTN_Open(rtn);
        RTN_InsertCall(rtn, IPOINT_BEFORE, 
            AFUNPTR(PrintfHander), 
            IARG_FUNCARG_ENTRYPOINT_VALUE, 0,
            IARG_END);
        RTN_Close(rtn);
    }
}
```

Наш `printf` oracle и новый `make_move`:

```c++
void PrintfHander(char * fmt)
{
    string str(fmt);
    // if we start a new game
    if (str.find("New game") != std::string::npos)
    {
        MineSweeper::pos = 0;
        MineSweeper::generate_solution();
    }

    // if we win
    if (str.find("Victory") != std::string::npos)
        MineSweeper::k_field++;
}

void make_move(unsigned int * row, unsigned int * col)
{
    PIN_LockClient();
    // get current empty position
    auto p = MineSweeper::solution[MineSweeper::pos++];
    *row = p.first;
    *col = p.second;
    PIN_UnlockClient();
}
```

После чего запускаем нашу программу под пином и через ~50 минут получаем флаг :)

Весь код доступен [здесь](https://github.com/archercreat/CTF-Writeups/blob/master/%D0%98%D0%BD%D0%B6%D0%B5%D0%BD%D0%B5%D1%80%D0%BD%D0%B0%D1%8F%20%D0%BF%D0%BE%D0%B4%D0%B3%D0%BE%D1%82%D0%BE%D0%B2%D0%BA%D0%B0/MyPinTool.cpp).

---

Конец.

