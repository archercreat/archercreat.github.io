---
title: Рекомпиляция байткода виртуальной машины с помощью LLVM
date: 2021-03-26 23:04:00 +07:00
tags: [LLVM, virtual machine]
image:
 path: /assets/img/posts/sprush_llvm/7tY1edP.png
 width: 1200
 height: 630
---

В прошлые выходные мы с командой играли SPRUSH CTF и поскольку у меня появилась свободная минута, хотелось бы рассказать о еще одной технике анализа вм на примере одного задания. 
В моих предыдущих статьях я, в основном, рассказывал о фреймворках `Miasm` и `Triton`. И хотя эти вещи хорошо справляются с работой, для анализа серьезных виртуальных машин (Enigma, VMP, ..) они не годятся. Никто не будет сидеть и анализировать картинку с Miasm IR функции на 1000+ строк. Хочется чего-то реального (ida pro F5 go brr).. И как вы могли догадаться по заголовку, речь пойдет об LLVM.

## LLVM
![](/assets/img/posts/sprush_llvm/7tY1edP.png)

Для тех, кто никогда не слышал об LLVM - это универсальная система анализа, трансформации и оптимизации программного кода, или как ее называют разработчики «compiler infrastucture». Хороший пример использования LLVM - компилятор clang.

В основе LLVM лежит LLVM IR (промежуточное представление кода), над которым можно производить трансформацию. LLVM очень удобен для написания своих компиляторов, поскольку весь функцианал для этого предоставляется "из коробки".

## LLVM IR
Если коротко, LLVM IR можно охарактеризовать как типизированный трехадресный код в SSA форме. Что такое SSA я объяснял [тут](https://archercreat.github.io/securinets_2020_vm_rev/), а трехадресный код - это последовательность операторов вида `x := y op z`, где `x`, `y` и `z` - это имена, константы или сгенерированные компилятором временные объекты. В правую часть после равно может входить только один знак операции.

Взглянем на текстовую форму LLVM IR на примере следующей функции:
```c++
int sum(int a, int b) {
  return a+b;
}
```
Компилятор `clang`, помимо компиляции, может создать файл с биткодом llvm:
```
clang sum.c -emit-llvm -S
```

Контент файла:

```llvm
; ModuleID = 'sum.c'
source_filename = "sum.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-pc-linux-gnu"

; Function Attrs: noinline nounwind optnone uwtable
define dso_local i32 @sum(i8 zeroext %0, i8 zeroext %1) #0 {
  %3 = alloca i8, align 1
  %4 = alloca i8, align 1
  store i8 %0, i8* %3, align 1
  store i8 %1, i8* %4, align 1
  %5 = load i8, i8* %3, align 1
  %6 = zext i8 %5 to i32
  %7 = load i8, i8* %4, align 1
  %8 = zext i8 %7 to i32
  %9 = add nsw i32 %6, %8
  ret i32 %9
}
```

Инструкции `alloca` создают переменные на стэке, а операции `load` и `store` считывают и записывают в них. Поскольку промежуточное представление строго типизированное, не обойтись без приведений типов, которые явно кодируются специальными инструкциями. Помимо этого есть возможность преобразования между целочисленными типами и указателями.

Сегодня мы опишем инструкции виртуальной машины с цтф в LLVM IR, пересоберем в исполняемый файл и запустим.

## Инициализируем контекст
Перед началом обработки инструкций необходимо проинициализировать контекст LLVM, указать внешние функции, создать регистры процессора и память.

Для начала создадим контекст:
```c++
LLVMContext context;
IRBuilder<NoFolder> builder(context);
Module program("my awesome program", context);
```

`IRBuilder` будет нужен для генерации промежуточного представления, а класс `Module` будет хранить всю информация о нашей программе.

Теперь создадим `main` функцию и укажем внешние зависимости. К счастью для нас, ВМ использует всего 2 внешние зависимости - `read` и `write`. LLVM достаточно указать имя и тип функции, чтобы компоновщик уже правильно все слинковал.

```cpp
// Create void main() function
auto type = FunctionType::get(builder.getVoidTy(), false);
auto func = Function::Create(type, Function::ExternalLinkage, "main", program);
// Add read
ArrayRef<Type*> args = { builder.getInt32Ty(), builder.getInt8Ty()->getPointerTo(), builder.getInt32Ty() };
type = FunctionType::get( builder.getInt32Ty(), args, false );
program.getOrInsertFunction( "read", type );
// Add write
args = { builder.getInt32Ty(), builder.getInt8Ty()->getPointerTo(), builder.getInt32Ty() };
type = FunctionType::get( builder.getInt32Ty(), args, false );
program.getOrInsertFunction( "write", type );
```

Теперь создадим регистры и память. У нашей ВМ всего 4 32-битных регистра и 2 регистра флагов. В качестве памяти используется массив размером 0x10000 байт. Так же у ВМ есть константные данные, они тоже хранятся в массиве. Укажем это:

```c++
// ZF conditional flag
utils::create_global( program, "ZF", builder.getInt1Ty() );
// OF conditional flag
utils::create_global( program, "OF", builder.getInt1Ty() );
// Set up registers R0-R3
for (int i = 0; i < 4; i++)
{
    utils::create_global( program, utils::fmt( "R%x", i ), builder.getInt32Ty() );
}

// Set up constant data
utils::create_global( program, "data", ArrayType::get( builder.getInt8Ty(), 0x1000 ), data );
// Set up memory
utils::create_global( program, "memory", ArrayType::get( builder.getInt8Ty(), 0x10000 ) );
```

Здесь наша функция `create_global` создает глобальную переменную и выставляет ей правильный тип.

С инициализацией закончили, можно переходить к обработке байткода.

## Пишем дизассемблер
Нам нужно научиться проходить по байткоду. Поскольку байткод статичный и мы знаем размер каждой инструкции, напишем дизассемблер, который будет дизассемблировать базовые блоки пока они не закончатся. Напомню, что базовый блок - список инструкций, которые выполняются непрерывно. При появлении условного перехода, вызова функции, инструкции возврата базовый блок заканчивается. В случае с условным переходом, создастся 2 новых блока: 1 - по адресу успешного условного перехода, 2 - адрес следующей инструкции.
Дизассемблер будет хранить список адресов уже дизассемблированных базовых блоков, и список адресов новых блоков. 

Примерный код:

```c++
// Basic blocks to disassemble
std::vector<size_t> todo{pc};
// Basic blocks already disassembled
std::vector<size_t> done;
...
while (!todo.empty())
{
    // Get basic block address
    pc = todo.back();
    todo.pop_back();
    done.push_back(pc);
    ...
    // Disassemble basic block
    while (1)
    {
        ...
        handler(instruction);
        pc += instruction.size();
        ...
        if (instruction.terminator)
            break;
    }
```

Если мы достигли инструкции, которая прерывает базовый блок - выходим из вложенного цикла и достаем новый адрес.
P.S. В данном случае функция `handler` создает LLVM IR для инструкций.

## Описываем инструкции
Мы перешли к самому интересному, нам необходимо описать каждую инструкцию байткода в LLVM IR. Кто читал статьи про Miasm заметит, что поднятие в LLVM IR практически ничем не отличается от поднятия в Miasm IR. Поскольку набор инструкций довольно мал и однотипен, приведу код нескольких обработчиков и соответствующее текстовое представление LLVM IR.

Инструкция `INC reg` (`reg += 1`).

```cpp
static void inc( instruction_info& info, context_info& context )
{
    auto[program, builder] = context.ctx();
    context.instructions.insert( { info.address, make_nop( builder ) } );
    // Get register number
    auto dst = info.byte<1>();
    // Get register instance
    auto dst_r = program.getNamedGlobal( utils::fmt("R%x", dst ) );
    // Load value from register
    auto dst_v = builder.CreateLoad( dst_r );
    // Increment by 1
    auto value = builder.CreateAdd( builder.getInt32( 1 ), dst_v );
    // Put value back into register
    builder.CreateStore( value, dst_r );
}
```
Генерирует биткод:
```llvm
%70 = load i32, i32* @R2
%71 = add i32 1, %70
store i32 %71, i32* @R2
```

Инструкция сравнения `CMP reg, reg`.

```cpp
static void cmp_reg_reg( instruction_info& info, context_info& context )
{
    auto[program, builder] = context.ctx();
    context.instructions.insert( { info.address, make_nop( builder ) } );
    auto reg1 = info.byte<1>();
    auto reg2 = info.byte<2>();

    auto reg1_r = program.getNamedGlobal( utils::fmt("R%x", reg1 ) );
    auto reg2_r = program.getNamedGlobal( utils::fmt("R%x", reg2 ) );
    auto zf_r   = program.getNamedGlobal( "ZF" );
    auto of_r   = program.getNamedGlobal( "OF" );

    auto reg1_v = builder.CreateLoad( reg1_r );
    auto reg2_v = builder.CreateLoad( reg2_r );

    builder.CreateStore( builder.CreateICmpEQ(  reg1_v, reg2_v ), zf_r );
    builder.CreateStore( builder.CreateICmpUGE( reg1_v, reg2_v ), of_r );
}
```
Генерирует биткод:

```llvm
%73 = load i32, i32* @R2
%74 = icmp eq i32 %73, 32
store i1 %74, i1* @ZF
%75 = icmp uge i32 %73, 32
store i1 %75, i1* @OF
```

## Рекомпилируем
После дизассемблирования всех инструкций, мы можем сохранить LLVM IR в файл и с помощью компилятора `clang` собрать его в нужную нам архитектуру с максимальной оптимизацией :)
Как выглядит наша функция в ассемблерном виде:

```llvm
@memory = internal global [65536 x i8] zeroinitializer

define void @main() {
"0x0":
  store i32 0, i32* @R0
  store i32 12, i32* @R1
  %3 = load i32, i32* @R0
  %4 = load i32, i32* @R1
  %5 = getelementptr inbounds [4096 x i8], [4096 x i8]* @data, i32 0, i32 %3
  %6 = call i32 @write(i32 1, i8* %5, i32 %4)
  ...
```

С помощью `clang` компилируем в `x86-64`:

```bash
clang-11 -o lift_O3_opt -O3 -march=native bytecode.ll
```

Что получилось:

![](/assets/img/posts/sprush_llvm/f4AU66F.png)

И оно даже работает!



## Решение
Как видно, программа записывает 32 байта нашего ввода по адресу `input`. После чего в цикле (он тут оптимизирован) ксорит каждый символ с числом и записывает это все в новый массив по адресу `output`, затем сверяет этот массив с массивом по адресу `flag`. 
P.S. While цикл криво скомпилировался, но все равно работает правильно.

Все решение:

```python
flag = [
    0x6E, 0x14, 0x50,
    0x72, 0x74, 0x6D, 0x44,
    0x44, 0x7D, 0x2B, 0x43,
    0x40, 0x4C, 0x40, 0x4B,
    0x75, 0x19, 0x4A, 0x2A,
    0x1E, 0x19, 0x4E, 0x4F,
    0x2B, 0x47, 0x2F, 0x56,
    0x2D, 0x18, 0x77, 0x43, 0x03]

pos = [
    0x0B, 0x07, 0x18,
    0x05, 0x00, 0x17, 0x1B,
    0x03, 0x06, 0x09, 0x0F,
    0x19, 0x12, 0x1A, 0x0C,
    0x08, 0x0D, 0x01, 0x02,
    0x11, 0x1E, 0x1D, 0x0E,
    0x10, 0x04, 0x15, 0x13,
    0x14, 0x1C, 0x1F, 0x0A, 0x16]

out = ''
for i in range(len(flag)):
    out += chr(flag[pos[i]] ^ (0x13 + i))
print(out)
```

Получаем флаг `SPR{y34h_7h15vm_c0uld_b3_b3773r}`

Можно проверить в рекомпилированной программе:

```
$ clang-11 -o lift_O3_opt -O3 -march=native bytecode.ll
$ ./lift_O3_opt
Enter_flag:_SPR{y34h_7h15vm_c0uld_b3_b3773r}
That's_right
$
```

## Полезные ссылки
[My First Language Frontend with LLVM Tutorial](https://llvm.org/docs/tutorial/MyFirstLanguageFrontend/index.html)

[Обзор LLVM](https://habr.com/ru/post/47878/)

Код и решение виртуальной машины доступны [здесь](https://github.com/archercreat/llvm_stuff/tree/master/sprushVM).

---

Конец.