import pdfplumber

from dataclasses import dataclass, field

import os
import sys
import math
import json
import re

@dataclass
class Route:
    start_location: str
    departure: float
    arrival: float
    number: int

@dataclass
class Locomotive:
    number: str
    service_ident: str
    distance: int

    prev_location: str = None
    prev_train_number: str = None
    prev_service_ident: str = None

    next_location: str = None
    next_train_number: str = None
    next_service_ident: str = None

    routes: list[Route] = field(default_factory=lambda: [])

    def flush_lines(self, prev_lines: list[str], next_lines: list[str]):
        if len(prev_lines) == 1:
            self.prev_location = None
            self.prev_service_ident = None
            self.prev_train_number = None
        else:
            self.prev_location = prev_lines[-1]

            service_idx = len(prev_lines) - 2
            try:
                # Only 'x_Dop-peltrak-tion' seems to be multiline
                service_idx = prev_lines.index('x_Dop')
                self.prev_service_ident = "".join(prev_lines[service_idx:service_idx+3])
            except ValueError:
                self.prev_service_ident = prev_lines[service_idx]

            self.prev_train_number = ""
            for i in range(service_idx):
                self.prev_train_number += prev_lines[i]

        if len(next_lines) == 1:
            self.next_location = None
            self.next_service_ident = None
            self.next_train_number = None
        else:
            self.next_location = next_lines[-1]

            service_idx = len(next_lines) - 2
            try:
                # Only 'x_Dop-peltrak-tion' seems to be multiline
                service_idx = next_lines.index('x_Dop')
                self.next_service_ident = "".join(next_lines[service_idx:service_idx+3])
            except ValueError:
                self.next_service_ident = next_lines[service_idx]

            self.next_train_number = ""
            for i in range(service_idx):
                self.next_train_number += next_lines[i]


def approx_equal(a, b, max_error = 0.05):
    return abs(a - b) < max_error

def approx_equal_tuple(a, b, max_error = 0.05):
    if type(a) != tuple or type(b) != tuple or len(a) != len(b):
        return False
    
    for ax, bx in zip(a, b):
        if abs(ax - bx) >= max_error:
            return False

    return True


def remap(x, srcMin, srcMax, dstMin, dstMax):
    return (x - srcMin) / (srcMax - srcMin) * (dstMax - dstMin) + dstMin

def format_time(hours):
    minutes = 60 * (hours % 1)

    return "%d:%02d" % (hours, round(minutes))

def main(input_path, output_dir):
    pdf = pdfplumber.open(input_path)

    all_locos = []
    target_date = None

    for page in pdf.pages:
        words = page.extract_words(keep_blank_chars=True)

        if not target_date:
            for word in words:
                m = re.match(r'(\d{2}).(\d{2}).(\d{4})\s*\[\w+\]', word['text'])
                if m:
                    target_date = m.groups()
                    break

        # Find locomotives
        locos = []
        loco_y = []
        curr_loco = Locomotive(None, None, None)
        curr_y = 0
        curr_prev_lines = []
        curr_prev_y = 0
        curr_next_lines = []
        curr_next_y = 0

        loco_x = 0
        from_x = 0
        to_x = 0
        for word in words:
            if word['text'] == 'FZG':
                loco_x = word['x0']
                continue
            if word['text'] == 'Von':
                from_x = word['x0'] + 0.9125434179773606
                continue
            if word['text'] == 'Nach':
                to_x = word['x0'] + 0.9125434179773038
                continue

            if word['top'] <= 50:
                continue

            if word['text'] == '621':
                pass

            if word['top'] - curr_y > 45:
                if curr_loco.number is not None:
                    curr_loco.flush_lines(curr_prev_lines, curr_next_lines)
                    locos.append(curr_loco)

                curr_loco = Locomotive(None, None, None)

            if approx_equal(word['x0'], loco_x, max_error=0.1):
                if curr_loco.number is None:
                    curr_loco.number = word['text']
                    curr_prev_lines = []
                    curr_next_lines = []
                    curr_y = word['top']
                    curr_prev_y = curr_next_y = 0
                    loco_y.append(word['top'])
                elif curr_loco.service_ident is None:
                    if word['text'] == 'x_Dop' or word['text'] == '(x_Dop':
                        curr_loco.service_ident = 'x_Doppeltraktion'
                    elif word['text'].startswith('x_Dop'):
                        curr_loco.service_ident = 'x_Doppeltraktion'
                        curr_prev_lines.append(word['text'][len('x_Dop'):])
                        curr_prev_y = word['top']
                    elif word['text'].startswith('(x_Dop'):
                        curr_loco.service_ident = 'x_Doppeltraktion'
                        curr_prev_lines.append(word['text'][len('(x_Dop'):])
                        curr_prev_y = word['top']
                    else:
                        curr_loco.service_ident = word['text'][1:-1]
                else:
                    try:
                        curr_loco.distance = int(word['text'][0:-3])
                    except:
                        curr_loco.distance = 0

            if approx_equal(word['x0'], from_x, max_error=0.1):
                if word['top'] - curr_prev_y < 5:
                    continue
                if curr_prev_y != 0 and word['top'] - curr_prev_y > 10:
                    curr_prev_lines.append('')
                curr_prev_lines.append(word['text'])
                curr_prev_y = word['top']

            if approx_equal(word['x0'], to_x, max_error=0.1):
                if curr_next_y != 0 and word['top'] - curr_next_y > 10:
                    curr_next_lines.append('')
                curr_next_lines.append(word['text'])
                curr_next_y = word['top']
        
        if curr_loco.number is not None:
            curr_loco.flush_lines(curr_prev_lines, curr_next_lines)
            locos.append(curr_loco)

        # Convert vertical into horizontal text
        for word1 in words:
            h_word = word1['text']
            used_words = [word1]
            last_word = word1
            max_x1 = word1['x1']
            changed = True
            while changed:
                changed = False
                for word2 in words:
                    if word1 == word2:
                        continue
                    if approx_equal(last_word['bottom'] - 0.95, word2['top'], 0.15) and approx_equal(word1['x0'], word2['x0'], 0.0001):
                        h_word += word2['text']
                        used_words.append(word2)
                        last_word = word2
                        max_x1 = max(max_x1, word2['x1'])
                        changed = True
                        break
            if len(used_words) > 1:
                words = [x for x in words if x not in used_words]
                words.append({'text': h_word, 'x0': word1['x0'], 'x1': max_x1, 'top': word1['top'], 'bottom': last_word['bottom']})
        
        # Find time marking lines
        hour0_x = None
        hour24_x = None
        for rect in page.rects:
            # Identify based on usual attributes
            if rect['height'] < 50 or rect['top'] < 50 or rect['top'] > 62 or not approx_equal_tuple(rect['non_stroking_color'], (0.625, 0.625, 0.625)):
                continue

            # Assumes they are orded in the PDF file, but they *should* be
            if hour0_x is None:
                hour0_x = rect['x0'] + rect['width']/2
            # Some lines - including 24h - are a bit thiner
            elif approx_equal(rect['width'], 0.84, max_error=0.2):
                hour24_x = rect['x0'] + rect['width']/2

        for i, rect in enumerate(page.rects):
            # Remove general noise
            if rect['top'] < 50 or rect['height'] < 4.8 or rect['height'] > 5.8:
                continue
            # They have a fill of black / gray / green
            if not rect['fill'] or not (approx_equal_tuple(rect['non_stroking_color'], (0.0, 0.0, 0.0)) or approx_equal_tuple(rect['non_stroking_color'], (0.0, 0.625, 0.0)) or approx_equal_tuple(rect['non_stroking_color'], (0.434082, 0.434082, 0.434082))):
                continue

            # Remap from PDF position
            start, end = remap(rect['x0'], hour0_x, hour24_x, 0, 24), remap(rect['x1'], hour0_x, hour24_x, 0, 24) 
            if end - start < 1 / 60.0:
                # Duration is less than a minute -> almost certainly noise
                continue

            # Find the appropriate train number
            train_number = None
            min_dist = float("inf")
            for i, word in enumerate(words):
                dist = rect['top'] - word['bottom']
                if word['x0'] >= rect['x0'] - 10 and word['x1'] <= rect['x1'] + 10 and dist >= -1 and dist < min_dist:
                    train_number = word['text']
                    min_dist = dist
                
            # Find starting point
            starting = None
            min_dist = float("-inf")
            for word in words:
                dist = rect['bottom'] - word['top']
                if approx_equal(word['x0'], rect['x0'], 1) and dist <= 0 and dist > min_dist:
                    starting = word['text']
                    min_dist = dist
            
            main_route = Route(starting, start, end, train_number)

            # Associate route with a locomotive
            min_dist = float("inf")
            loco = None
            for i, y in enumerate(loco_y):
                dist = rect['top'] - y
                if dist >= 0 and dist < min_dist:
                    loco = locos[i]
                    min_dist = dist

            if loco is None:
                print(f"Unknown route: {main_route}")
                continue

            loco.routes.append(main_route)

        all_locos += locos
        # break

    result = {}
    trains = {}

    print(f"Dumping {len(all_locos)} locomotives...")
    result["locomotives"] = []
    for loco in all_locos:
        routes_result = []
        for i, main_route in enumerate(loco.routes):
            position = None
            train_number = main_route.number
            if train_number is None:
                print(f"Skipping invalid {main_route}")
                continue
            
            if main_route.number[0] < '0' or main_route.number[0] > '9' and main_route.number[0] != 'R':
                position = main_route.number[0]

                if main_route.number[1] == '|':
                    train_number = main_route.number[2:]
                else:
                    train_number = main_route.number[1:]

            dep_minute = int(round(main_route.departure*60))
            arr_minute = int(round(main_route.arrival*60)) - 1

            destination = None
            if i + 1 < len(loco.routes):
                destination = loco.routes[i + 1].start_location
            elif loco.next_location is not None:
                destination = loco.next_location

            route_result = {
                "origin_location": main_route.start_location,
                "destination_location": destination,

                "locomotive_position": position,
                "train_number": train_number,

                "departure_time": {
                    "hour": int(math.floor(dep_minute / 60)),
                    "minute": dep_minute % 60,
                },
                "arrival_time": {
                    "hour": int(math.floor(arr_minute / 60)),
                    "minute": arr_minute % 60,
                },
            }
            routes_result.append(route_result)

            train_key = (train_number, dep_minute)
            if not train_key in trains:
                trains[train_key] = { loco.number: route_result }
            else:
                trains[train_key][loco.number] = route_result

        result["locomotives"].append({
            "number": int(loco.number),
            "service_identifier": loco.service_ident if loco.service_ident != '-' else None,
            "distance_km": int(loco.distance),
            "yesterday": {
                "location": loco.prev_location,
                "train_number": loco.prev_train_number,
                "service_identifier": loco.prev_service_ident,
            },
            "tomorrow": {
                "location": loco.next_location,
                "train_number": loco.next_train_number,
                "service_identifier": loco.next_service_ident,
            },
            "routes": routes_result,
        })

    print(f"Dumping {len(trains)} trains...")
    result["trains"] = []
    for train_key in trains:
        routes = trains[train_key]
        route_keys = list(routes)
        main_route = routes[route_keys[0]]

        destination = main_route["destination_location"]
        route_idx = 1
        while destination is None and route_idx < len(route_keys):
            destination = routes[route_keys[route_idx]]["destination_location"]
            route_idx += 1

        def get_position(routes, loco_number):
            role = routes[loco_number]["locomotive_position"]

            if role == 'D': # D is always first
                return 0
            if role == 'F': # F is always second
                return 1
            if role == 'B': # B is always third
                return 2
            if role == 'C': # C is always fourth
                return 3
            
            if role == 'A': # A is sometimes second, but maybe first if there is only one locomotive
                return min(len(routes) - 1, 1)

            if role == 'S': # Towed locomotives are always last TODO: What about multiple towed?
                return len(routes) - 1

            return 0 # No qualifier means there are no other locomotives

        result["trains"].append({
            "origin_location": main_route["origin_location"],
            "destination_location": destination,
            "departure_time": main_route["departure_time"],
            "arrival_time": main_route["arrival_time"],

            "number": train_key[0],

            "locomotives": sorted([{
                "number": int(loco_number),
                "role": routes[loco_number]["locomotive_position"],
                "position": get_position(routes, loco_number)
            } for loco_number in routes], key=lambda loco: loco["position"]),
        })

    print(f"Writing .json files into '{output_dir}'")
    with open(os.path.join(output_dir, f"{target_date[2]}_{target_date[1]}_{target_date[0]}.json"), "w") as f:
        json.dump(result, f, indent=4)
    with open(os.path.join(output_dir, f"{target_date[2]}_{target_date[1]}_{target_date[0]}.min.json"), "w") as f:
        json.dump(result, f)

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])



