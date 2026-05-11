import sys
import os
import time
import requests

base_url = sys.argv[1]
target_dir = sys.argv[2]

session = requests.session()
# Tor uses the 9050 port as the default socks port
session.proxies = {'http':  'socks5://127.0.0.1:9050',
                   'https': 'socks5://127.0.0.1:9050'}

settings_url = f"{base_url}/settings.json"
archive_url = f"{base_url}/archive_calendar.json"

res = session.get(settings_url)
if res.status_code != 200:
    print(f"Failed to fetch Roundshot settings: {res.body}")
    exit(1)

settings = res.json()
storage_key = None

if len(settings["list"]) == 1:
    storage_key = settings["list"][list(settings["list"])[0]]["preview_url"].split("/")[3]
else:
    print("Please select the correct webcam:")

    while True:
        try:
            for idx, key in enumerate(settings["list"]):
                print(f"[{idx + 1}] '{settings["list"][key]["name"]}'")

            i = int(input().strip()) - 1
            storage_key = settings["list"][list(settings["list"])[i]]["preview_url"].split("/")[3]
            break
        except ValueError:
            print("Incorrect value! Please select the correct webcam:")

res = session.get(archive_url)
if res.status_code != 200:
    print(f"Failed to fetch Roundshot archive: {res.body}")
    exit(1)

archive = res.json()

start_date = (2019, 7, 16)
start_date = (2022, 10, 29)
# end_date = (2023, 4, 30)
end_date = (10000, 0, 0)

for year in archive:
    if year['y'] < start_date[0]:
        continue
    if year['y'] > end_date[0]:
        continue
    
    for month in year['months']:
        if year['y'] == start_date[0] and month['m'] < start_date[1]:
            continue
        if year['y'] == end_date[0] and month['m'] > end_date[1]:
            continue

        for day in month['days']:
            if year['y'] == start_date[0] and month['m'] == start_date[1] and day['d'] < start_date[2]:
                continue
            if year['y'] == end_date[0] and month['m'] == end_date[1] and day['d'] > end_date[2]:
                continue

            print(f"Trying day {year['y']}-{month['m']:0>2}-{day['d']:0>2}...")

            hour_range = None
            if month['m'] == 1:
                hour_range = range(7, 17)
            elif month['m'] == 2:
                hour_range = range(6, 18)
            elif month['m'] == 3:
                hour_range = range(6, 20)
            elif month['m'] >= 4 and month['m'] <= 8:
                hour_range = range(5, 21)
            elif month['m'] == 9:
                hour_range = range(6, 20)
            elif month['m'] == 10:
                hour_range = range(6, 19)
            elif month['m'] == 11:
                hour_range = range(6, 17)
            elif month['m'] == 12:
                hour_range = range(7, 16)

            hour_range = range(8, 18)
            
            for hour in hour_range:
                subminute = -10
                for minute in range(0, 60, 1):
                    if minute % 3 != 0 and minute % 10 != 0:
                        continue
                    
                    image_dir  = f"{year['y']}-{month['m']:0>2}-{day['d']:0>2}"
                    image_name = f"{year['y']}-{month['m']:0>2}-{day['d']:0>2}_{hour:0>2}-{minute:0>2}-00.jpg"

                    dir = os.path.join(target_dir, image_dir)
                    path = os.path.join(dir, image_name)
                    if os.path.exists(path):
                        continue
                    
                    timeout = 1
                    url = f"https://storage2.roundshot.com/54746c4b1386b2.69857289/{year['y']}-{month['m']:0>2}-{day['d']:0>2}/{hour:0>2}-{minute:0>2}-00/{year['y']}-{month['m']:0>2}-{day['d']:0>2}-{hour:0>2}-{minute:0>2}-00_full.jpg"
                    
                    while True:
                        time.sleep(timeout)
                        res = session.get(url, stream=True)
                        if res.status_code == 429:
                            print(f"* Timeout: Sleeping for {timeout}s")
                            timeout *= 2
                            continue
                        else:
                            timeout = 1
                            break
                        
                    if res.status_code == 404:
                        print(f"* Not found {hour:0>2}:{minute:0>2}")
                        continue
                        # subminute = max(subminute, minute - 10)

                        # found = False
                        # while subminute < minute + 10:
                        #     if subminute % 3 != 0 or subminute % 10 == 0:
                        #         subminute += 1
                        #         continue

                        #     realhour = (hour - 1) if subminute < 0 else ( (hour + 1) if subminute >= 60 else (hour) )
                        #     realminute = subminute % 60

                        #     url = f"https://storage2.roundshot.com/54746c4b1386b2.69857289/{year['y']}-{month['m']:0>2}-{day['d']:0>2}/{realhour:0>2}-{realminute:0>2}-00/{year['y']}-{month['m']:0>2}-{day['d']:0>2}-{realhour:0>2}-{realminute:0>2}-00_full.jpg"
                            
                        #     while True:
                        #         time.sleep(timeout)
                        #         res = session.get(url, stream=True)
                        #         if res.status_code == 429:
                        #             print(f"  -> Timeout: Sleeping for {timeout}s")
                        #             timeout *= 2
                        #             continue
                        #         else:
                        #             timeout = 1
                        #             break

                        #     if res.status_code != 200:
                        #         print(f"  -> miss {realhour:0>2}:{realminute:0>2}")
                        #         subminute += 1
                        #         continue
                        #     else:
                        #         print(f"  -> GOOD {realhour:0>2}:{realminute:0>2}")
                        #         found = True

                        #         image_name = f"{year['y']}-{month['m']:0>2}-{day['d']:0>2}_{realhour:0>2}-{realminute:0>2}-00.jpg"
                        #         path = os.path.join(dir, image_name)

                        #         subminute += 1
                        #         break

                        # if not found:
                        #     continue

                    # if os.path.exists(path):
                    #     continue

                    print(f"- Saved '{image_name}'")

                    os.makedirs(dir, exist_ok=True)
                    with open(path, "wb") as f:
                        f.write(res.content)
            break
        break
    break


