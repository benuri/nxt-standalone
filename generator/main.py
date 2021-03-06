#!/usr/bin/env python2
# Copyright 2017 The NXT Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

############################################################
# COMMON
############################################################
from collections import namedtuple

class Name:
    def __init__(self, name, native=False):
        self.native = native
        if native:
            self.chunks = [name]
        else:
            self.chunks = name.split(' ')

    def CamelChunk(self, chunk):
        return chunk[0].upper() + chunk[1:]

    def canonical_case(self):
        return (' '.join(self.chunks)).lower()

    def concatcase(self):
        return ''.join(self.chunks)

    def camelCase(self):
        return self.chunks[0] + ''.join([self.CamelChunk(chunk) for chunk in self.chunks[1:]])

    def CamelCase(self):
        return ''.join([self.CamelChunk(chunk) for chunk in self.chunks])

    def SNAKE_CASE(self):
        return '_'.join([chunk.upper() for chunk in self.chunks])

    def snake_case(self):
        return '_'.join(self.chunks)

class Type:
    def __init__(self, name, record, native=False):
        self.record = record
        self.dict_name = name
        self.name = Name(name, native=native)
        self.category = record['category']
        self.is_builder = self.name.canonical_case().endswith(" builder")

EnumValue = namedtuple('EnumValue', ['name', 'value'])
class EnumType(Type):
    def __init__(self, name, record):
        Type.__init__(self, name, record)
        self.values = [EnumValue(Name(m['name']), m['value']) for m in self.record['values']]

BitmaskValue = namedtuple('BitmaskValue', ['name', 'value'])
class BitmaskType(Type):
    def __init__(self, name, record):
        Type.__init__(self, name, record)
        self.values = [BitmaskValue(Name(m['name']), m['value']) for m in self.record['values']]
        self.full_mask = 0
        for value in self.values:
            self.full_mask = self.full_mask | value.value

class NativeType(Type):
    def __init__(self, name, record):
        Type.__init__(self, name, record, native=True)

class MethodArgument:
    def __init__(self, name, typ, annotation):
        self.name = name
        self.type = typ
        self.annotation = annotation
        self.length = None

Method = namedtuple('Method', ['name', 'return_type', 'arguments'])
class ObjectType(Type):
    def __init__(self, name, record):
        Type.__init__(self, name, record)
        self.methods = []

############################################################
# PARSE
############################################################
import json
def link_object(obj, types):
    def make_method(record):
        arguments = []
        arguments_by_name = {}
        for a in record.get('args', []):
            arg = MethodArgument(Name(a['name']), types[a['type']], a.get('annotation', 'value'))
            arguments.append(arg)
            arguments_by_name[arg.name.canonical_case()] = arg

        for (arg, a) in zip(arguments, record.get('args', [])):
            assert(arg.annotation == 'value' or 'length' in a)
            if arg.annotation != 'value':
                if a['length'] == 'strlen':
                    arg.length = 'strlen'
                else:
                    arg.length = arguments_by_name[a['length']]

        return Method(Name(record['name']), types[record.get('returns', 'void')], arguments)

    obj.methods = [make_method(m) for m in obj.record.get('methods', [])]

def parse_json(json):
    category_to_parser = {
        'bitmask': BitmaskType,
        'enum': EnumType,
        'native': NativeType,
        'object': ObjectType,
    }

    types = {}

    by_category = {}
    for name in category_to_parser.keys():
        by_category[name] = []

    for (name, record) in json.items():
        if name[0] == '_':
            continue
        category = record['category']
        parsed = category_to_parser[category](name, record)
        by_category[category].append(parsed)
        types[name] = parsed

    for obj in by_category['object']:
        link_object(obj, types)

    for category in by_category.keys():
        by_category[category] = sorted(by_category[category], key=lambda typ: typ.name.canonical_case())

    return {
        'types': types,
        'by_category': by_category
    }

#############################################################
# OUTPUT
#############################################################
import re, os, sys
from collections import OrderedDict

try:
    import jinja2
except ImportError:
    # Try using Chromium's Jinja2
    dir, _ = os.path.split(os.path.realpath(__file__))
    third_party_dir = os.path.normpath(dir + (os.path.sep + os.path.pardir) * 2)
    sys.path.insert(1, third_party_dir)
    import jinja2

# A custom Jinja2 template loader that removes the extra indentation
# of the template blocks so that the output is correctly indented
class PreprocessingLoader(jinja2.BaseLoader):
    def __init__(self, path):
        self.path = path

    def get_source(self, environment, template):
        path = os.path.join(self.path, template)
        if not os.path.exists(path):
            raise jinja2.TemplateNotFound(template)
        mtime = os.path.getmtime(path)
        with open(path) as f:
            source = self.preprocess(f.read())
        return source, path, lambda: mtime == os.path.getmtime(path)

    blockstart = re.compile('{%-?\s*(if|for|block)[^}]*%}')
    blockend = re.compile('{%-?\s*end(if|for|block)[^}]*%}')

    def preprocess(self, source):
        lines = source.split('\n')

        # Compute the current indentation level of the template blocks and remove their indentation
        result = []
        indentation_level = 0

        for line in lines:
            # The capture in the regex adds one element per block start or end so we divide by two
            # there is also an extra line chunk corresponding to the line end, so we substract it.
            numends = (len(self.blockend.split(line)) - 1) / 2
            indentation_level -= numends

            result.append(self.remove_indentation(line, indentation_level))

            numstarts = (len(self.blockstart.split(line)) - 1) / 2
            indentation_level += numstarts

        return '\n'.join(result)

    def remove_indentation(self, line, n):
        for _ in range(n):
            if line.startswith(' '):
                line = line[4:]
            elif line.startswith('\t'):
                line = line[1:]
            else:
                assert(line.strip() == '')
        return line

FileRender = namedtuple('FileRender', ['template', 'output', 'params_dicts'])

def do_renders(renders, template_dir, output_dir):
    env = jinja2.Environment(loader=PreprocessingLoader(template_dir), trim_blocks=True, lstrip_blocks=True, line_comment_prefix='//*')
    for render in renders:
        params = {}
        for param_dict in render.params_dicts:
            params.update(param_dict)
        output = env.get_template(render.template).render(**params)

        output_file = output_dir + os.path.sep + render.output
        directory = os.path.dirname(output_file)
        if not os.path.exists(directory):
            os.makedirs(directory)

        content = ""
        try:
            with open(output_file, 'r') as outfile:
                content = outfile.read()
        except:
            pass

        if output != content:
            with open(output_file, 'w') as outfile:
                outfile.write(output)

#############################################################
# MAIN SOMETHING WHATEVER
#############################################################
import argparse, sys

def as_varName(*names):
    return names[0].camelCase() + ''.join([name.CamelCase() for name in names[1:]])

def as_cType(name):
    if name.native:
        return name.concatcase()
    else:
        return 'nxt' + name.CamelCase()

def as_cppType(name):
    if name.native:
        return name.concatcase()
    else:
        return name.CamelCase()

def decorate(name, typ, arg):
    if arg.annotation == 'value':
        return typ + ' ' + name
    elif arg.annotation == '*':
        return typ + '* ' + name
    elif arg.annotation == 'const*':
        return typ + ' const * ' + name
    else:
        assert(False)

def annotated(typ, arg):
    name = as_varName(arg.name)
    return decorate(name, typ, arg)

def as_cEnum(type_name, value_name):
    assert(not type_name.native and not value_name.native)
    return 'NXT' + '_' + type_name.SNAKE_CASE() + '_' + value_name.SNAKE_CASE()

def as_cppEnum(value_name):
    assert(not value_name.native)
    if value_name.concatcase()[0].isdigit():
        return "e" + value_name.CamelCase()
    return value_name.CamelCase()

def as_cMethod(type_name, method_name):
    assert(not type_name.native and not method_name.native)
    return 'nxt' + type_name.CamelCase() + method_name.CamelCase()

def as_MethodSuffix(type_name, method_name):
    assert(not type_name.native and not method_name.native)
    return type_name.CamelCase() + method_name.CamelCase()

def as_cProc(type_name, method_name):
    assert(not type_name.native and not method_name.native)
    return 'nxt' + 'Proc' + type_name.CamelCase() + method_name.CamelCase()

def as_backendType(typ):
    if typ.category == 'object':
        return typ.name.CamelCase() + '*'
    else:
        return as_cType(typ.name)

def native_methods(types, typ):
    return [
        Method(Name('reference'), types['void'], []),
        Method(Name('release'), types['void'], []),
    ] + typ.methods

def debug(text):
    print(text)

def main():
    targets = ['nxt', 'nxtcpp', 'mock_nxt', 'opengl', 'metal', 'wire', 'blink']

    parser = argparse.ArgumentParser(
        description = 'Generates code for various target for NXT.',
        formatter_class = argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument('json', metavar='NXT_JSON', nargs=1, type=str, help ='The NXT JSON definition to use.')
    parser.add_argument('-t', '--template-dir', default='templates', type=str, help='Directory with template files.')
    parser.add_argument('-o', '--output-dir', default=None, type=str, help='Output directory for the generated source files.')
    parser.add_argument('-T', '--targets', default=None, type=str, help='Comma-separated subset of targets to output. Available targets: ' + ', '.join(targets))
    parser.add_argument('--print-dependencies', action='store_true', help='Prints a space separated list of file dependencies, used for CMake integration')
    parser.add_argument('--print-outputs', action='store_true', help='Prints a space separated list of file outputs, used for CMake integration')
    parser.add_argument('--gn', action='store_true', help='Make the printing of dependencies by GN friendly')

    args = parser.parse_args()

    if args.targets != None:
        targets = args.targets.split(',')

    with open(args.json[0]) as f:
        loaded_json = json.loads(f.read())

    api_params = parse_json(loaded_json)

    base_params = {
        'enumerate': enumerate,
        'format': format,
        'len': len,
        'debug': debug,

        'Name': lambda name: Name(name),

        'as_annotated_cType': lambda arg: annotated(as_cType(arg.type.name), arg),
        'as_annotated_cppType': lambda arg: annotated(as_cppType(arg.type.name), arg),
        'as_cEnum': as_cEnum,
        'as_cppEnum': as_cppEnum,
        'as_cMethod': as_cMethod,
        'as_MethodSuffix': as_MethodSuffix,
        'as_cProc': as_cProc,
        'as_cType': as_cType,
        'as_cppType': as_cppType,
        'as_varName': as_varName,
        'decorate': decorate,
        'native_methods': lambda typ: native_methods(api_params['types'], typ)
    }

    renders = []

    if 'nxt' in targets:
        renders.append(FileRender('api.h', 'nxt/nxt.h', [base_params, api_params]))
        renders.append(FileRender('api.c', 'nxt/nxt.c', [base_params, api_params]))

    if 'nxtcpp' in targets:
        renders.append(FileRender('apicpp.h', 'nxt/nxtcpp.h', [base_params, api_params]))
        renders.append(FileRender('apicpp.cpp', 'nxt/nxtcpp.cpp', [base_params, api_params]))

    if 'mock_nxt' in targets:
        renders.append(FileRender('mock_api.h', 'mock/mock_nxt.h', [base_params, api_params]))
        renders.append(FileRender('mock_api.cpp', 'mock/mock_nxt.cpp', [base_params, api_params]))

    base_backend_params = [
        base_params,
        api_params,
        {
            'as_backendType': lambda typ: as_backendType(typ), # TODO as_backendType and friends take a Type and not a Name :(
            'as_annotated_backendType': lambda arg: annotated(as_backendType(arg.type), arg)
        }
    ]

    if 'opengl' in targets:
        opengl_params = {
            'namespace': 'opengl',
        }
        renders.append(FileRender('BackendProcTable.cpp', 'opengl/ProcTable.cpp', base_backend_params + [opengl_params]))

    if 'metal' in targets:
        metal_params = {
            'namespace': 'metal',
        }
        renders.append(FileRender('BackendProcTable.cpp', 'metal/ProcTable.mm', base_backend_params + [metal_params]))

    if 'wire' in targets:
        renders.append(FileRender('wire/WireCmd.h', 'wire/WireCmd_autogen.h', base_backend_params))
        renders.append(FileRender('wire/WireCmd.cpp', 'wire/WireCmd.cpp', base_backend_params))
        renders.append(FileRender('wire/WireClient.cpp', 'wire/WireClient.cpp', base_backend_params))
        renders.append(FileRender('wire/WireServer.cpp', 'wire/WireServer.cpp', base_backend_params))

    if 'blink' in targets:
        renders.append(FileRender('blink/autogen.gni', 'autogen.gni', [base_params, api_params]))
        renders.append(FileRender('blink/Objects.cpp', 'NXT.cpp', [base_params, api_params]))
        renders.append(FileRender('blink/Forward.h', 'Forward.h', [base_params, api_params]))

        for typ in api_params['by_category']['object']:
            file_prefix = 'NXT' + typ.name.CamelCase()
            params = [base_params, api_params, {'type': typ}]

            renders.append(FileRender('blink/Object.h', file_prefix + '.h', params))
            renders.append(FileRender('blink/Object.idl', file_prefix + '.idl', params))

    output_separator = '\n' if args.gn else ';'
    if args.print_dependencies:
        dependencies = set(
            [os.path.abspath(args.template_dir + os.path.sep + render.template) for render in renders] + 
            [os.path.abspath(args.json[0])] +
            [os.path.realpath(__file__)]
        )
        sys.stdout.write(output_separator.join(dependencies))
        return 0

    if args.print_outputs:
        outputs = set(
            [os.path.abspath(args.output_dir + os.path.sep + render.output) for render in renders]
        )
        sys.stdout.write(output_separator.join(outputs))
        return 0

    do_renders(renders, args.template_dir, args.output_dir)

if __name__ == '__main__':
    sys.exit(main())
