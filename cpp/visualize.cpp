
#include <opencv2/highgui/highgui.hpp>

#include <sstream>
#include <stdio.h>

#include "visualize.h"
#include "keypoints.h"

using namespace cv;


/// Draw an image to a file or to the screen.
// Overlay the image with the information about keypoints.
void draw_image(Mat big_image, Keypoint *fs, int n, int frame_id, bool draw_images, std::string directory) 
{
	int biw = big_image.cols, bih = big_image.rows;
	int iw = 1600, ih = (iw * bih) / biw;
	Mat image;
	resize(big_image, image, Size(iw, ih), 0, 0);
	
	//-- Draw features
	for (int i = 0; i < n; i++) {
		double px = rad_to_px_horizontal(fs[i].px, image.cols);
		double py = rad_to_px_vertical(fs[i].py, image.rows);
		
		cv::circle(image, Point(px,py), (9*pow(1.2,fs[i].octave)/2)*iw/biw, Scalar(255,0,255), 2);
		int halfsize = 31*pow(1.2, fs[i].octave)/2 *iw/biw;
		cv::rectangle(image, Point(px-halfsize, py-halfsize), Point(px+halfsize, py+halfsize), Scalar(255,0,0,128),2);
		
		std::stringstream ss; ss << fs[i].id;
		string text = ss.str();
		
		cv::putText(image, 
					text, 
					Point(px,py),
					FONT_HERSHEY_SCRIPT_SIMPLEX, 
					0.5, 
					Scalar(0,255,0));
					
	}

	if (!directory.empty()) {
		char tmp[256]; sprintf(tmp, "%s/frame_%04d.jpg", directory.c_str(), frame_id);
		string str(tmp);
		imwrite(str, image);
	}
	if (draw_images)
		imshow("Keypoints", image );
}
